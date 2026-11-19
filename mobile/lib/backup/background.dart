/// The automatic backup: a periodic workmanager job that runs
/// [BackupRunner.runOnce] for up to 9 minutes; and "Back up now": a
/// one-off long-running job with a notification (D-038).
///
/// ```
///  settings ─► planBackgroundTask ─► registerPeriodicTask(every 15 min,
///                                     unmetered network if Wi-Fi only,
///                                     charging if asked, battery not low)
///                                  └► cancelByUniqueName (backup off)
///
///  Android wakes the app ─► backupCallbackDispatcher (own isolate)
///    ─► runBackgroundBackup:  settings off? not paired? lock taken? → stop
///         IdentityStore + SqfliteBackupStateStore + AddressBook
///         connect: cached addresses only (last LAN, WireGuard), NO mDNS:
///         the multicast lock is foreground only (D-012, spec §13)
///         runOnce(9 min) ─► last_run saved for the Status screen
///
///  "Back up now" ─► registerOneOffTask(foreground service, dataSync,
///                   notification "Backing up your photos")
///    ─► runBackgroundBackup(manual): no backup-on / Wi-Fi rule, up to 5 h,
///         every second: stop_requested? → cancel; every minute: lock refreshed
///         progress (≤ 2/s) + "done" ─► app through workmanager progress
/// ```
///
/// The app's Hello names (`client_software`, `device_name`) travel in
/// the task's input data, so the background job introduces itself
/// exactly like the app. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:haotrannas_client/app/client_providers.dart'
    show connectPairedOrThrow;
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/backup/media_source.dart';
import 'package:haotrannas_client/client/address_book.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/client/upload_engine.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:workmanager/workmanager.dart';

import 'photo_media_source.dart';

const backupTaskUniqueName = 'haotrannas-auto-backup';
const backupTaskName = 'auto-backup';
const manualBackupTaskUniqueName = 'haotrannas-backup-now';
const manualBackupTaskName = 'backup-now';

/// "Back up now" runs at most this long. ⚪ Android 15 allows a dataSync
/// foreground service about 6 h a day.
const manualRunBudget = Duration(hours: 5);

/// The long job reports progress at most this often.
const progressReportInterval = Duration(milliseconds: 500);

/// How often the long job looks for "stop" and refreshes the run lock.
const stopCheckInterval = Duration(seconds: 1);
const runLockRefreshInterval = Duration(minutes: 1);

/// Android's shortest period for periodic work.
const backgroundRunInterval = Duration(minutes: 15);

const _clientSoftwareKey = 'client_software';
const _deviceNameKey = 'device_name';

/// What to ask workmanager for. Pure, so it is easy to test.
final class BackgroundTaskPlan {
  const BackgroundTaskPlan({
    required this.isScheduled,
    required this.networkType,
    required this.isChargingRequired,
  });

  final bool isScheduled;

  /// `unmetered` (Wi-Fi) when Wi-Fi only, else any `connected` network.
  final NetworkType networkType;
  final bool isChargingRequired;

  Constraints get constraints => Constraints(
    networkType: networkType,
    requiresCharging: isChargingRequired,
    requiresBatteryNotLow: true,
  );
}

BackgroundTaskPlan planBackgroundTask(BackupSettings settings) =>
    BackgroundTaskPlan(
      isScheduled: settings.isBackupOn,
      networkType: settings.isWifiOnly
          ? NetworkType.unmetered
          : NetworkType.connected,
      isChargingRequired: settings.isChargingOnly,
    );

Map<String, dynamic> backgroundInputData({
  required String clientSoftware,
  required String deviceName,
}) => {_clientSoftwareKey: clientSoftware, _deviceNameKey: deviceName};

/// Schedules the job with workmanager. Off Android it does nothing (the
/// plugin is not there in desktop runs and tests).
class WorkmanagerBackupScheduler implements BackupScheduler {
  WorkmanagerBackupScheduler({
    required this.clientSoftware,
    required this.deviceName,
  });

  final String clientSoftware;
  final String deviceName;

  @override
  Future<void> apply(BackupSettings settings) async {
    if (!Platform.isAndroid) return;
    final plan = planBackgroundTask(settings);
    if (!plan.isScheduled) {
      await Workmanager().cancelByUniqueName(backupTaskUniqueName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      backupTaskUniqueName,
      backupTaskName,
      frequency: backgroundRunInterval,
      constraints: plan.constraints,
      // update: keeps the schedule, applies new constraints and input.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      inputData: backgroundInputData(
        clientSoftware: clientSoftware,
        deviceName: deviceName,
      ),
    );
  }
}

/// "Back up now" through workmanager (Android only).
class WorkmanagerManualBackupLauncher implements ManualBackupLauncher {
  WorkmanagerManualBackupLauncher({
    required this.clientSoftware,
    required this.deviceName,
  });

  final String clientSoftware;
  final String deviceName;

  /// Native side: `MainActivity.kt`.
  static const _notificationChannel = MethodChannel(
    'vn.haotran.haotrannas_mobile/notifications',
  );

  @override
  Future<void> start() async {
    try {
      // Android 13+: without it the backup still runs, only unseen.
      await _notificationChannel.invokeMethod<bool>('request');
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
    await Workmanager().registerOneOffTask(
      manualBackupTaskUniqueName,
      manualBackupTaskName,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      inputData: backgroundInputData(
        clientSoftware: clientSoftware,
        deviceName: deviceName,
      ),
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'HaoTranNAS',
        notificationText: 'Backing up your photos',
        notificationChannelId: 'haotrannas_backup',
        notificationChannelName: 'Backup',
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  }

  @override
  Future<bool> isRunning() async {
    final info = await Workmanager().getWorkInfo(manualBackupTaskUniqueName);
    return info?.state == WorkState.running ||
        info?.state == WorkState.scheduled;
  }

  @override
  void listen(void Function(Map<String, Object?> progress) onProgress) =>
      unawaited(
        Workmanager().setProgressListener((uniqueName, progress) {
          if (uniqueName == manualBackupTaskUniqueName) onProgress(progress);
        }),
      );
}

/// Call once in `main()` before scheduling. Off Android it does nothing.
Future<void> initializeBackgroundBackup() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(backupCallbackDispatcher);
}

/// Android's entry point for the job; runs in a fresh isolate.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask(_runFromPlugin);
}

Future<bool> _runFromPlugin(
  String taskName,
  Map<String, dynamic>? inputData,
) async {
  final identityStore = await IdentityStore.forApp();
  final stateStore = await SqfliteBackupStateStore.openForApp(databaseFactory);
  try {
    await runBackgroundBackup(
      taskName: taskName,
      inputData: inputData,
      reportProgress: (progress) => Workmanager().reportProgress(progress),
      loadIdentity: identityStore.load,
      stateStore: stateStore,
      mediaSource: PhotoManagerMediaSource(isBackground: true),
      connectPaired:
          (identity, {required clientSoftware, required deviceName}) =>
              connectPairedOrThrow(
                AddressBook(
                  clientSoftware: clientSoftware,
                  deviceName: deviceName,
                  store: identityStore,
                ),
                identity,
                // No mDNS in the background (D-012): cached addresses only.
              ),
    );
  } finally {
    await stateStore.close();
  }
  // Always "done": the 15-minute period is the retry; WorkManager's own
  // retry would only wake the phone again for the same offline server.
  return true;
}

typedef PairedConnector = Future<NasConnection> Function(
  DeviceIdentity identity, {
  required String clientSoftware,
  required String deviceName,
});

enum BackgroundOutcome {
  /// Another task name (not ours).
  notOurTask,

  /// The user turned automatic backup off.
  backupOff,
  notPaired,

  /// The pairing files are there but unusable.
  identityDamaged,

  /// Registered without the Hello names (should not happen).
  missingInputData,

  /// The app or another job holds the run lock.
  busy,

  /// [BackupRunner.runOnce] ran; see the saved `last_run`.
  ran,

  /// The run threw (plugin or disk error); `last_run` says why.
  failed,
}

/// What the background job does, without any plugin call: tests drive it
/// with fakes. Never throws for a run problem: the report records it.
Future<({BackgroundOutcome outcome, BackupRunReport? report})>
runBackgroundBackup({
  required String taskName,
  required Map<String, dynamic>? inputData,
  required Future<DeviceIdentity?> Function() loadIdentity,
  required BackupStateStore stateStore,
  required MediaSource mediaSource,
  required PairedConnector connectPaired,
  Future<void> Function(Map<String, Object?> progress)? reportProgress,
  DateTime Function()? clock,
  Duration? budget,
  Duration stopCheckEvery = stopCheckInterval,
}) async {
  final now = clock ?? DateTime.now;
  final startedAt = now();
  final isManual = taskName == manualBackupTaskName;

  /// Only the manual job reports; a failed report never stops the run.
  Future<void> report({BackupProgress? progress, String? problem}) async {
    if (!isManual || reportProgress == null) return;
    try {
      await reportProgress(
        encodeWorkerProgress(
          isDone: progress == null,
          startedAt: startedAt,
          progress: progress,
          problem: problem,
        ),
      );
    } on Exception catch (_) {}
  }

  Future<({BackgroundOutcome outcome, BackupRunReport? report})> stopped(
    BackgroundOutcome outcome, {
    String? problem,
  }) async {
    await report(problem: problem);
    return (outcome: outcome, report: null);
  }

  if (taskName != backupTaskName && !isManual) {
    return (outcome: BackgroundOutcome.notOurTask, report: null);
  }
  final settings = decodeSettings(
    await stateStore.readValue(settingsValueName),
  );
  if (!isManual && !settings.isBackupOn) {
    return stopped(BackgroundOutcome.backupOff);
  }
  final clientSoftware = inputData?[_clientSoftwareKey];
  final deviceName = inputData?[_deviceNameKey];
  if (clientSoftware is! String || deviceName is! String) {
    return stopped(
      BackgroundOutcome.missingInputData,
      problem: 'The backup job started without its settings.',
    );
  }
  final DeviceIdentity? identity;
  try {
    identity = await loadIdentity();
  } on IdentityDamaged {
    return stopped(
      BackgroundOutcome.identityDamaged,
      problem: 'The pairing files are damaged: unpair and pair again.',
    );
  }
  if (identity == null) {
    return stopped(
      BackgroundOutcome.notPaired,
      problem: 'This phone is not paired.',
    );
  }
  final pairedIdentity = identity;

  final lockOwner = 'background-${now().microsecondsSinceEpoch}';
  if (!await stateStore.claimRunLock(lockOwner, now().millisecondsSinceEpoch)) {
    return stopped(
      BackgroundOutcome.busy,
      problem: '${BackupController.busyText} (in the background)',
    );
  }
  final cancel = UploadCancel();
  Timer? stopWatch;
  if (isManual) {
    var lastLockRefreshAt = now();
    stopWatch = Timer.periodic(stopCheckEvery, (_) async {
      try {
        final stopText = await stateStore.readValue(stopRequestedValueName);
        if (stopText == stopRequestedYes) cancel.cancel();
        if (now().difference(lastLockRefreshAt) >= runLockRefreshInterval) {
          lastLockRefreshAt = now();
          // A long run must not look dead to the periodic job.
          await stateStore.claimRunLock(
            lockOwner,
            now().millisecondsSinceEpoch,
          );
        }
      } on Exception catch (_) {}
    });
  }
  DateTime? lastReportAt;
  void onProgress(BackupProgress progress) {
    final at = now();
    if (lastReportAt != null &&
        at.difference(lastReportAt!) < progressReportInterval) {
      return;
    }
    lastReportAt = at;
    unawaited(report(progress: progress));
  }

  try {
    final runner = BackupRunner(
      mediaSource: mediaSource,
      stateStore: stateStore,
      connect: () => connectPaired(
        pairedIdentity,
        clientSoftware: clientSoftware,
        deviceName: deviceName,
      ),
      clock: now,
    );
    final BackupRunReport runReport;
    try {
      runReport = await runner.runOnce(
        folderIds: settings.chosenFolderIds,
        budget: budget ?? (isManual ? manualRunBudget : defaultRunBudget),
        cancel: cancel,
        onProgress: onProgress,
      );
    } on Exception catch (error) {
      // A plugin or disk error outside the per-item handling.
      await stateStore.writeValue(
        lastRunValueName,
        encodeRunSummary(
          BackupRunSummary(
            finishedAt: now(),
            filesUploaded: 0,
            filesAlreadyBackedUp: 0,
            filesFailed: 0,
            bytesUploaded: 0,
            problem: 'Background backup stopped by an error: $error',
          ),
        ),
      );
      return await stopped(BackgroundOutcome.failed);
    }
    await stateStore.writeValue(
      lastRunValueName,
      encodeRunSummary(summaryOfRun(runReport)),
    );
    await report();
    return (outcome: BackgroundOutcome.ran, report: runReport);
  } finally {
    stopWatch?.cancel();
    await stateStore.releaseRunLock(lockOwner);
  }
}
