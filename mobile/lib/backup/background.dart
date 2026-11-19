/// The automatic backup: a periodic workmanager job that runs
/// [BackupRunner.runOnce] for up to 9 minutes.
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
/// ```
///
/// The app's Hello names (`client_software`, `device_name`) travel in
/// the task's input data, so the background job introduces itself
/// exactly like the app. Author: Hao Tran.
library;

import 'dart:io';

import 'package:workmanager/workmanager.dart';

import '../client/address_book.dart';
import '../client/identity.dart';
import '../client/nas_connection.dart';
import '../ui/backup_status_source.dart';
import 'backup_controller.dart';
import 'backup_runner.dart';
import 'backup_state_store.dart';
import 'media_source.dart';

const backupTaskUniqueName = 'haotrannas-auto-backup';
const backupTaskName = 'auto-backup';

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
  final stateStore = await SqfliteBackupStateStore.openForApp();
  try {
    await runBackgroundBackup(
      taskName: taskName,
      inputData: inputData,
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

/// [AddressBook.connectPaired] as a [NasConnector]: the connection, or
/// [BackupConnectFailed] with the address book's message.
Future<NasConnection> connectPairedOrThrow(
  AddressBook addressBook,
  DeviceIdentity identity, {
  List<DiscoveredServer> discovered = const [],
}) async {
  final result = await addressBook.connectPaired(
    identity,
    discovered: discovered,
  );
  return switch (result) {
    PairedConnected(:final connection) => connection,
    PairedConnectFailed(:final kind, :final message) =>
      throw BackupConnectFailed(
        message,
        isMaybeNotPaired: kind == PairedConnectFailureKind.maybeNotPaired,
      ),
  };
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
  DateTime Function()? clock,
  Duration budget = defaultRunBudget,
}) async {
  final now = clock ?? DateTime.now;
  ({BackgroundOutcome outcome, BackupRunReport? report}) stopped(
    BackgroundOutcome outcome,
  ) => (outcome: outcome, report: null);

  if (taskName != backupTaskName) return stopped(BackgroundOutcome.notOurTask);
  final settings = decodeSettings(
    await stateStore.readValue(settingsValueName),
  );
  if (!settings.isBackupOn) return stopped(BackgroundOutcome.backupOff);
  final clientSoftware = inputData?[_clientSoftwareKey];
  final deviceName = inputData?[_deviceNameKey];
  if (clientSoftware is! String || deviceName is! String) {
    return stopped(BackgroundOutcome.missingInputData);
  }
  final DeviceIdentity? identity;
  try {
    identity = await loadIdentity();
  } on IdentityDamaged {
    return stopped(BackgroundOutcome.identityDamaged);
  }
  if (identity == null) return stopped(BackgroundOutcome.notPaired);
  final pairedIdentity = identity;

  final lockOwner = 'background-${now().microsecondsSinceEpoch}';
  if (!await stateStore.claimRunLock(lockOwner, now().millisecondsSinceEpoch)) {
    return stopped(BackgroundOutcome.busy);
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
    final BackupRunReport report;
    try {
      report = await runner.runOnce(budget: budget);
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
      return stopped(BackgroundOutcome.failed);
    }
    await stateStore.writeValue(
      lastRunValueName,
      encodeRunSummary(summaryOfRun(report)),
    );
    return (outcome: BackgroundOutcome.ran, report: report);
  } finally {
    await stateStore.releaseRunLock(lockOwner);
  }
}
