// The background job's logic through runBackgroundBackup (no plugin
// calls) and the schedule plan.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/testing/backup_fakes.dart';
import 'package:haotrannas_mobile/backup/background.dart';
import 'package:workmanager/workmanager.dart';

DeviceIdentity testIdentity() => DeviceIdentity(
  deviceId: 1,
  certDer: [1, 2, 3],
  keyPkcs8Der: [4, 5, 6],
  serverCertSha256: List.filled(32, 7),
);

void main() {
  group('planBackgroundTask', () {
    test('defaults: on, Wi-Fi (unmetered) only, any charge state', () {
      final plan = planBackgroundTask(const BackupSettings());
      expect(plan.isScheduled, isTrue);
      expect(plan.networkType, NetworkType.unmetered);
      expect(plan.isChargingRequired, isFalse);
      expect(plan.constraints.requiresBatteryNotLow, isTrue);
    });

    test('mobile data allowed, charging only, off', () {
      final plan = planBackgroundTask(
        const BackupSettings(isWifiOnly: false, isChargingOnly: true),
      );
      expect(plan.networkType, NetworkType.connected);
      expect(plan.constraints.requiresCharging, isTrue);
      expect(
        planBackgroundTask(const BackupSettings(isBackupOn: false)).isScheduled,
        isFalse,
      );
    });

    test('15 minutes is the period (Android minimum)', () {
      expect(backgroundRunInterval, const Duration(minutes: 15));
      expect(defaultRunBudget, const Duration(minutes: 9));
    });
  });

  group('runBackgroundBackup', () {
    late Directory folder;
    late FakeMediaSource media;
    late MemoryBackupStateStore store;
    late FakeNas nas;
    late List<
      ({DeviceIdentity identity, String clientSoftware, String deviceName})
    >
    connects;
    DeviceIdentity? identity;
    final reports = <Map<String, Object?>>[];

    setUp(() async {
      folder = Directory.systemTemp.createTempSync('backup_background');
      media = FakeMediaSource(folder);
      store = MemoryBackupStateStore();
      nas = await FakeNas.start();
      connects = [];
      identity = testIdentity();
      reports.clear();
    });

    tearDown(() async {
      await nas.close();
      folder.deleteSync(recursive: true);
    });

    Future<({BackgroundOutcome outcome, BackupRunReport? report})> run({
      String taskName = backupTaskName,
      Map<String, dynamic>? inputData,
      Future<DeviceIdentity?> Function()? loadIdentity,
    }) => runBackgroundBackup(
      taskName: taskName,
      reportProgress: (progress) async => reports.add(progress),
      inputData:
          inputData ??
          backgroundInputData(
            clientSoftware: 'haotrannas-mobile 0.1.0',
            deviceName: 'Android phone',
          ),
      loadIdentity: loadIdentity ?? () async => identity,
      stateStore: store,
      mediaSource: media,
      connectPaired:
          (paired, {required clientSoftware, required deviceName}) async {
            connects.add((
              identity: paired,
              clientSoftware: clientSoftware,
              deviceName: deviceName,
            ));
            return nas.connect();
          },
    );

    test(
      'runs the backup with the app\'s Hello names, saves last_run',
      () async {
        media.put('a', [1, 2, 3]);

        final result = await run();

        expect(result.outcome, BackgroundOutcome.ran);
        expect(result.report!.filesUploaded, 1);
        expect(connects.single.clientSoftware, 'haotrannas-mobile 0.1.0');
        expect(connects.single.deviceName, 'Android phone');
        expect(connects.single.identity.deviceId, 1);
        final saved = decodeRunSummary(await store.readValue(lastRunValueName));
        expect(saved!.filesUploaded, 1);
        expect(
          await store.claimRunLock('app', 0),
          isTrue,
          reason: 'lock released',
        );
      },
    );

    test('server offline: report says so, still "ran"', () async {
      media.put('a', [1]);
      nas.connectFailure = const BackupConnectFailed('No address worked');

      final result = await run();

      expect(result.outcome, BackgroundOutcome.ran);
      expect(result.report!.stopReason, BackupStopReason.connectFailed);
      final saved = decodeRunSummary(await store.readValue(lastRunValueName));
      expect(saved!.problem, contains('No address worked'));
    });

    test('backup turned off: nothing happens', () async {
      await store.writeValue(
        settingsValueName,
        encodeSettings(const BackupSettings(isBackupOn: false)),
      );
      media.put('a', [1]);

      final result = await run();

      expect(result.outcome, BackgroundOutcome.backupOff);
      expect(connects, isEmpty);
    });

    test('not paired, damaged identity, other task, missing input', () async {
      identity = null;
      expect((await run()).outcome, BackgroundOutcome.notPaired);
      expect(
        (await run(
          loadIdentity: () async => throw const IdentityDamaged('bad json'),
        )).outcome,
        BackgroundOutcome.identityDamaged,
      );
      expect(
        (await run(taskName: 'something-else')).outcome,
        BackgroundOutcome.notOurTask,
      );
      identity = testIdentity();
      expect(
        (await run(inputData: const {})).outcome,
        BackgroundOutcome.missingInputData,
      );
      expect(connects, isEmpty);
    });

    test('the app holds the run lock: busy, nothing uploaded', () async {
      media.put('a', [1]);
      await store.claimRunLock('app-1', DateTime.now().millisecondsSinceEpoch);

      final result = await run();

      expect(result.outcome, BackgroundOutcome.busy);
      expect(connects, isEmpty);
    });

    test('an unexpected error is saved as last_run problem', () async {
      final failing = _ThrowingMediaSource(media);
      final result = await runBackgroundBackup(
        taskName: backupTaskName,
        inputData: backgroundInputData(clientSoftware: 'c', deviceName: 'd'),
        loadIdentity: () async => identity,
        stateStore: store,
        mediaSource: failing,
        connectPaired: (
          paired, {
          required clientSoftware,
          required deviceName,
        }) => nas.connect(),
      );

      expect(result.outcome, BackgroundOutcome.failed);
      final saved = decodeRunSummary(await store.readValue(lastRunValueName));
      expect(saved!.problem, contains('scan failed'));
      expect(await store.claimRunLock('app', 0), isTrue);
    });
  });

  group('"Back up now" job', () {
    late Directory folder;
    late FakeMediaSource media;
    late MemoryBackupStateStore store;
    late FakeNas nas;
    final reports = <Map<String, Object?>>[];

    setUp(() async {
      folder = Directory.systemTemp.createTempSync('backup_manual');
      media = FakeMediaSource(folder);
      store = MemoryBackupStateStore();
      nas = await FakeNas.start();
      reports.clear();
    });

    tearDown(() async {
      await nas.close();
      folder.deleteSync(recursive: true);
    });

    Future<({BackgroundOutcome outcome, BackupRunReport? report})> runManual({
      String taskName = manualBackupTaskName,
    }) => runBackgroundBackup(
      taskName: taskName,
      inputData: backgroundInputData(
        clientSoftware: 'haotrannas-mobile 0.1.0',
        deviceName: 'Android phone',
      ),
      loadIdentity: () async => testIdentity(),
      stateStore: store,
      mediaSource: media,
      reportProgress: (progress) async => reports.add(progress),
      connectPaired: (paired, {required clientSoftware, required deviceName}) =>
          nas.connect(),
    );

    test(
      'runs even with automatic backup off; reports, ends with done',
      () async {
        await store.writeValue(
          settingsValueName,
          encodeSettings(const BackupSettings(isBackupOn: false)),
        );
        media.put('a', [1, 2, 3]);

        final result = await runManual();

        expect(result.outcome, BackgroundOutcome.ran);
        expect(result.report!.filesUploaded, 1);
        expect(reports, isNotEmpty);
        expect(reports.first['state'], 'running');
        expect(reports.last['state'], 'done');
        final saved = decodeRunSummary(await store.readValue(lastRunValueName));
        expect(saved!.filesUploaded, 1);
      },
    );

    test('the automatic job reports nothing', () async {
      media.put('a', [1]);
      await runManual(taskName: backupTaskName);
      expect(reports, isEmpty);
    });

    test('busy: done with the reason', () async {
      expect(
        await store.claimRunLock('app', DateTime.now().millisecondsSinceEpoch),
        isTrue,
      );

      final result = await runManual();

      expect(result.outcome, BackgroundOutcome.busy);
      expect(reports.single['state'], 'done');
      expect(reports.single['problem'], contains('already running'));
    });

    test('stop_requested stops the job', () async {
      media.put('a', [1]);
      final gate = media.accessGate = Completer<void>();
      final running = runBackgroundBackup(
        taskName: manualBackupTaskName,
        inputData: backgroundInputData(
          clientSoftware: 'haotrannas-mobile 0.1.0',
          deviceName: 'Android phone',
        ),
        loadIdentity: () async => testIdentity(),
        stateStore: store,
        mediaSource: media,
        reportProgress: (progress) async => reports.add(progress),
        connectPaired: (
          paired, {
          required clientSoftware,
          required deviceName,
        }) => nas.connect(),
        stopCheckEvery: const Duration(milliseconds: 5),
      );
      await store.writeValue(stopRequestedValueName, stopRequestedYes);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();

      final result = await running;

      expect(result.report!.stopReason, BackupStopReason.cancelled);
      expect(nas.committedPaths(), isEmpty);
      expect(reports.last['state'], 'done');
    });
  });
}

class _ThrowingMediaSource extends FakeMediaSource {
  _ThrowingMediaSource(FakeMediaSource base) : super(base.folder);

  @override
  Stream<Never> listItems({Set<String>? folderIds}) =>
      Stream.error(Exception('scan failed'));
}
