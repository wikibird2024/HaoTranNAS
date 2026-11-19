// BackupController + the BackupStatusSource adapter: notifications,
// activity, summaries, saved settings, the shared run lock.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/testing/backup_fakes.dart';

class FakeLauncher implements ManualBackupLauncher {
  int startCalls = 0;
  bool isJobRunning = false;
  Exception? failure;
  void Function(Map<String, Object?> progress)? onProgress;

  @override
  Future<void> start() async {
    startCalls++;
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<bool> isRunning() async => isJobRunning;

  @override
  void listen(void Function(Map<String, Object?> progress) onProgress) =>
      this.onProgress = onProgress;
}

class FakeScheduler implements BackupScheduler {
  final applied = <BackupSettings>[];
  Exception? failure;

  @override
  Future<void> apply(BackupSettings settings) async {
    applied.add(settings);
    final error = failure;
    if (error != null) throw error;
  }
}

void main() {
  late Directory folder;
  late FakeMediaSource media;
  late MemoryBackupStateStore store;
  late FakeNas nas;
  late FakeScheduler scheduler;
  late List<String> logNotes;
  late BackupController controller;
  late BackupControllerStatusSource source;
  late int notifications;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('backup_controller');
    media = FakeMediaSource(folder);
    store = MemoryBackupStateStore();
    nas = await FakeNas.start();
    scheduler = FakeScheduler();
    logNotes = [];
    controller = BackupController(
      runner: BackupRunner(
        mediaSource: media,
        stateStore: store,
        connect: nas.connect,
      ),
      stateStore: store,
      scheduler: scheduler,
      log: logNotes.add,
      lockOwner: 'app-test',
    );
    source = BackupControllerStatusSource(controller);
    notifications = 0;
    source.addListener(() => notifications++);
  });

  tearDown(() async {
    source.dispose();
    controller.dispose();
    await nas.close();
    folder.deleteSync(recursive: true);
  });

  /// Lets unawaited work finish.
  Future<void> settle() async {
    for (
      var round = 0;
      round < 50 && controller.activity != BackupActivity.idle;
      round++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('start: reads saved settings and summaries, schedules', () async {
    const saved = BackupSettings(isWifiOnly: false, isChargingOnly: true);
    await store.writeValue(settingsValueName, encodeSettings(saved));
    final run = BackupRunSummary(
      finishedAt: DateTime.fromMillisecondsSinceEpoch(1763450000000),
      filesUploaded: 4,
      filesAlreadyBackedUp: 1,
      filesFailed: 0,
      bytesUploaded: 99,
      problem: 'from the background job',
    );
    await store.writeValue(lastRunValueName, encodeRunSummary(run));

    await controller.start();

    expect(source.settings.isWifiOnly, isFalse);
    expect(source.settings.isChargingOnly, isTrue);
    expect(source.lastRun!.filesUploaded, 4);
    expect(source.lastRun!.problem, 'from the background job');
    expect(source.lastVerify, isNull);
    expect(scheduler.applied.single.isChargingOnly, isTrue);
    expect(notifications, greaterThan(0));
  });

  test('runNow: backingUp at once, then idle with a summary', () async {
    media.put('a', [1, 2, 3]);
    final activities = <BackupActivity>[];
    source.addListener(() => activities.add(source.activity));

    await source.runNow();
    expect(
      source.activity,
      BackupActivity.backingUp,
      reason: 'started before runNow returned',
    );
    await settle();

    expect(source.activity, BackupActivity.idle);
    expect(activities.first, BackupActivity.backingUp);
    expect(activities.last, BackupActivity.idle);
    expect(source.lastRun!.filesUploaded, 1);
    expect(source.lastRun!.bytesUploaded, 3);
    expect(controller.lastReport!.stopReason, BackupStopReason.finished);
    expect(
      decodeRunSummary(await store.readValue(lastRunValueName))!.filesUploaded,
      1,
      reason: 'saved for the next app start',
    );
    expect(
      await store.claimRunLock('other', 0),
      isTrue,
      reason: 'lock released',
    );
  });

  test('verifyAll: verifying, then a verify summary', () async {
    media.put('a', [1, 2, 3]);
    await controller.runNow();

    await source.verifyAll();
    expect(source.activity, BackupActivity.verifying);
    await settle();

    expect(source.lastVerify!.filesChecked, 1);
    expect(source.lastVerify!.filesWrong, 0);
    expect(source.lastVerify!.problem, isNull);
    expect(
      decodeVerifySummary(await store.readValue(lastVerifyValueName)),
      isNotNull,
    );
  });

  test('busy: a second run while one runs is refused', () async {
    media.put('a', [1]);
    media.accessGate = Completer<void>();
    final first = controller.runNow();
    expect(controller.activity, BackupActivity.backingUp);

    final refused = await controller.runNow();

    expect(refused, isNull);
    expect(controller.lastRunSummary!.problem, BackupController.busyText);
    media.accessGate!.complete();
    expect((await first)!.filesUploaded, 1);
    expect(controller.activity, BackupActivity.idle);
  });

  test('stop: cancels the running backup', () async {
    media.put('a', [1]);
    media.put('b', [2]);
    media.accessGate = Completer<void>();
    final run = controller.runNow();
    controller.stop();
    media.accessGate!.complete();

    final report = await run;

    expect(report!.stopReason, BackupStopReason.cancelled);
    expect(report.filesUploaded, 0);
  });

  test('busy: the background job holds the lock', () async {
    await store.claimRunLock(
      'background-1',
      DateTime.now().millisecondsSinceEpoch,
    );

    final report = await controller.runNow();

    expect(report, isNull);
    expect(source.lastRun!.problem, contains('in the background'));
    expect(source.activity, BackupActivity.idle);
  });

  test('updateSettings: saved, rescheduled, listeners told', () async {
    const changed = BackupSettings(isBackupOn: false);

    await source.updateSettings(changed);

    expect(source.settings.isBackupOn, isFalse);
    expect(
      decodeSettings(await store.readValue(settingsValueName)).isBackupOn,
      isFalse,
    );
    expect(scheduler.applied.single.isBackupOn, isFalse);
    expect(notifications, 1);
  });

  test('a scheduling failure is logged, not thrown', () async {
    scheduler.failure = Exception('no plugin');

    await source.updateSettings(const BackupSettings(isChargingOnly: true));
    await controller.start();

    expect(logNotes, hasLength(2));
    expect(logNotes.first, contains('no plugin'));
  });

  test('controller disposed during a run: the run ends quietly', () async {
    media.put('a', [1]);
    media.accessGate = Completer<void>();
    final shortLived = BackupController(
      runner: BackupRunner(
        mediaSource: media,
        stateStore: store,
        connect: nas.connect,
      ),
      stateStore: store,
      scheduler: scheduler,
    );
    final run = shortLived.runNow();
    shortLived.dispose();
    media.accessGate!.complete();

    final report = await run;

    expect(report!.stopReason, BackupStopReason.cancelled);
  });

  test('dispose stops forwarding', () async {
    final other = BackupControllerStatusSource(controller);
    var otherNotifications = 0;
    other.addListener(() => otherNotifications++);
    other.dispose();

    await controller.updateSettings(const BackupSettings());

    expect(otherNotifications, 0);
    expect(notifications, 1);
  });

  group('saved forms', () {
    test('settings round-trip; junk → defaults', () {
      const settings = BackupSettings(
        isBackupOn: false,
        isWifiOnly: false,
        isChargingOnly: true,
      );
      final back = decodeSettings(encodeSettings(settings));
      expect(back.isBackupOn, isFalse);
      expect(back.isWifiOnly, isFalse);
      expect(back.isChargingOnly, isTrue);

      for (final junk in [null, '', 'not json', '[1]', '{"backup_on":"yes"}']) {
        final defaults = decodeSettings(junk);
        expect(defaults.isBackupOn, isTrue, reason: '$junk');
        expect(defaults.isWifiOnly, isTrue);
        expect(defaults.isChargingOnly, isFalse);
      }
    });

    test('run summary keeps files left; old saved ones read as 0', () {
      final run = BackupRunSummary(
        finishedAt: DateTime(2026, 11, 19),
        filesUploaded: 3,
        filesAlreadyBackedUp: 1,
        filesFailed: 0,
        bytesUploaded: 10,
        filesLeft: 37,
      );
      expect(decodeRunSummary(encodeRunSummary(run))!.filesLeft, 37);
      expect(
        decodeRunSummary(
          '{"finished_at_ms":1,"files_uploaded":0,'
          '"files_already_backed_up":0,"files_failed":0,"bytes_uploaded":0}',
        )!.filesLeft,
        0,
      );
    });

    test('summaries: junk → null', () {
      expect(decodeRunSummary('{"finished_at_ms":"x"}'), isNull);
      expect(decodeVerifySummary('nope'), isNull);
    });

    test('summaryOfRun: first failure becomes the problem', () {
      final report = BackupRunReport(
        startedAt: DateTime(2026),
        finishedAt: DateTime(2026),
        stopReason: BackupStopReason.finished,
        itemsScanned: 2,
        itemsPicked: 2,
        filesUploaded: 1,
        filesAlreadyBackedUp: 0,
        bytesUploaded: 10,
        failures: const [(remotePath: 'DCIM/x.jpg', message: 'gone')],
      );
      final summary = summaryOfRun(report);
      expect(summary.filesFailed, 1);
      expect(summary.problem, contains('DCIM/x.jpg'));
    });

    test('summaryOfVerify: repaired files count as wrong', () {
      final report = VerifyReport(
        startedAt: DateTime(2026),
        finishedAt: DateTime(2026),
        stopReason: BackupStopReason.finished,
        filesChecked: 5,
        filesRepaired: 2,
        filesNotOnPhone: 0,
        filesChangedOnPhone: 0,
        failures: const [(remotePath: 'a', message: 'b')],
      );
      final summary = summaryOfVerify(report);
      expect(summary.filesWrong, 2);
      expect(summary.problem, '1 files could not be checked');
    });
  });

  group('folders', () {
    test(
      'never chosen: Camera is ticked; a choice is passed to the run',
      () async {
        media
          ..folderNames['shots'] = 'Screenshots'
          ..put('a', [1])
          ..put('s', [2], folderIds: {'shots'});

        final folders = await controller.loadFolders();
        expect(
          [for (final folder in folders) folder.name],
          ['Camera', 'Screenshots'],
        );
        expect([for (final folder in folders) folder.isChosen], [true, false]);

        await controller.updateSettings(
          const BackupSettings(chosenFolderIds: {'shots'}),
        );
        final report = await controller.runNow();
        expect(media.lastListedFolderIds, {'shots'});
        expect(report!.filesUploaded, 1);
        expect(nas.offeredPaths(), ['DCIM/Camera/s.jpg']);
      },
    );

    test('settings keep folder ids; old saved settings have none', () {
      const settings = BackupSettings(chosenFolderIds: {'b', 'a'});
      expect(decodeSettings(encodeSettings(settings)).chosenFolderIds, {
        'a',
        'b',
      });
      expect(
        decodeSettings('{"backup_on":true}').chosenFolderIds,
        isNull,
        reason: 'saved before D-037: Camera default',
      );
      expect(decodeSettings('{"folder_ids":[1]}').chosenFolderIds, isNull);
    });

    test('settings keep folder names for display (D-042)', () {
      const settings = BackupSettings(
        chosenFolderIds: {'cam'},
        chosenFolderNames: ['Camera', 'WhatsApp Images'],
      );
      expect(decodeSettings(encodeSettings(settings)).chosenFolderNames, [
        'Camera',
        'WhatsApp Images',
      ]);
      expect(
        decodeSettings('{"folder_ids":["cam"]}').chosenFolderNames,
        isNull,
      );
      expect(decodeSettings('{"folder_names":[1]}').chosenFolderNames, isNull);
      expect(
        settings.copyWith(isWifiOnly: false).chosenFolderNames,
        settings.chosenFolderNames,
      );
    });
  });

  group('in-app run progress', () {
    test('runNow shows live numbers, then clears them', () async {
      media.put('a', [1, 2, 3]);
      final seen = <BackupLiveProgress>[];
      source.addListener(() {
        final progress = source.progress;
        if (progress != null) seen.add(progress);
      });

      await controller.runNow();

      expect(seen, isNotEmpty);
      expect(seen.first.itemsTotal, 1);
      expect(source.progress, isNull);
    });
  });

  group('long backup job (launcher)', () {
    late FakeLauncher launcher;
    late BackupController jobController;

    setUp(() {
      launcher = FakeLauncher();
      jobController = BackupController(
        runner: BackupRunner(
          mediaSource: media,
          stateStore: store,
          connect: nas.connect,
        ),
        stateStore: store,
        scheduler: scheduler,
        manualLauncher: launcher,
        lockOwner: 'app-job-test',
      );
    });

    tearDown(() => jobController.dispose());

    test('runNow queues the job, does not run here', () async {
      media.put('a', [1]);
      await jobController.start();
      final report = await jobController.runNow();

      expect(report, isNull);
      expect(launcher.startCalls, 1);
      expect(jobController.activity, BackupActivity.backingUp);
      expect(
        nas.offeredPaths(),
        isEmpty,
        reason: 'the job uploads, not the app',
      );
      expect(await store.readValue(stopRequestedValueName), 'no');
    });

    test('job progress → live numbers; done → idle + saved summary', () async {
      await jobController.start();
      await jobController.runNow();
      final startedAt = DateTime(2026, 11, 19, 14);
      launcher.onProgress!(
        encodeWorkerProgress(
          isDone: false,
          startedAt: startedAt,
          progress: const BackupProgress(
            itemsDone: 12,
            itemsTotal: 80,
            currentPath: 'DCIM/Camera/x.jpg',
            filesUploaded: 3,
            bytesUploaded: 4096,
          ),
        ),
      );
      final live = jobController.progress!;
      expect(live.itemsChecked, 12);
      expect(live.itemsTotal, 80);
      expect(live.filesUploaded, 3);
      expect(live.bytesUploaded, 4096);
      expect(live.currentPath, 'DCIM/Camera/x.jpg');
      expect(live.startedAt, startedAt);

      final saved = BackupRunSummary(
        finishedAt: DateTime(2026, 11, 19, 15),
        filesUploaded: 3,
        filesAlreadyBackedUp: 0,
        filesFailed: 0,
        bytesUploaded: 4096,
      );
      await store.writeValue(lastRunValueName, encodeRunSummary(saved));
      await jobController.onWorkerProgress(
        encodeWorkerProgress(isDone: true, startedAt: startedAt),
      );
      expect(jobController.activity, BackupActivity.idle);
      expect(jobController.progress, isNull);
      expect(jobController.lastRunSummary!.filesUploaded, 3);
    });

    test('job done with a problem (busy) shows the problem', () async {
      await jobController.start();
      await jobController.runNow();
      await jobController.onWorkerProgress(
        encodeWorkerProgress(
          isDone: true,
          startedAt: DateTime(2026),
          problem: 'A backup is already running. (in the background)',
        ),
      );
      expect(jobController.lastRunSummary!.problem, contains('already'));
    });

    test('stop asks the job through the store', () async {
      await jobController.start();
      await jobController.runNow();
      launcher.isJobRunning = true;
      await jobController.stop();
      expect(jobController.activity, BackupActivity.backingUp);
      expect(await store.readValue(stopRequestedValueName), stopRequestedYes);
    });

    test('Stop when the job died without "done": idle again', () async {
      await jobController.start();
      await jobController.runNow();
      launcher.isJobRunning = false;
      await jobController.stop();
      expect(jobController.activity, BackupActivity.idle);
    });

    test('app opened while the job runs: shows backing up', () async {
      launcher.isJobRunning = true;
      await jobController.start();
      expect(jobController.activity, BackupActivity.backingUp);
    });

    test('job could not be queued: idle again, problem shown', () async {
      launcher.failure = Exception('no workmanager');
      await jobController.start();
      await jobController.runNow();
      expect(jobController.activity, BackupActivity.idle);
      expect(jobController.lastRunSummary!.problem, contains('no workmanager'));
    });

    test('a map this app did not write is ignored', () async {
      await jobController.start();
      await jobController.onWorkerProgress({'state': 'weird'});
      expect(jobController.activity, BackupActivity.idle);
    });
  });
}
