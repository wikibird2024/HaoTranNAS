/// The app's handle on backup: run now, verify, settings, last results;
/// and the adapter the screens see ([BackupControllerStatusSource]).
///
/// ```
///  Screens ─► BackupControllerStatusSource ─► BackupController
///              (BackupStatusSource)            │ runNow ─► ManualBackupLauncher (Android:
///                                              │           long-running job, D-038)
///                                              │           └─ no launcher: BackupRunner here
///                                              │ worker progress ─► onWorkerProgress ─► progress
///                                              │ stop ─► stop_requested value + cancel
///                                              │ verifyAll ─► BackupRunner (here)
///                                              │ updateSettings ─► store + BackupScheduler
///                                              ▼
///          SqfliteBackupStateStore: settings, last_run, last_verify, run_lock, stop_requested
/// ```
///
/// Settings and summaries live in the same SQLite file as the item
/// records (not a JSON file, not shared_preferences): one file the
/// background job already opens, written atomically by SQLite. The
/// background job writes `last_run` there too, so the app shows it.
///
/// Settings only shape the automatic background job; "Back up now" is
/// the user's explicit tap and runs on any network. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../client/upload_engine.dart';
import 'backup_runner.dart';
import 'backup_state_store.dart';
import 'backup_status_source.dart';
import 'media_source.dart';

/// Names in the store's `app_values` table.
const settingsValueName = 'settings';
const lastRunValueName = 'last_run';
const lastVerifyValueName = 'last_verify';

/// `yes` asks the running long backup job to stop (the app and the job
/// run in different isolates; this shared value is how they talk).
const stopRequestedValueName = 'stop_requested';
const stopRequestedYes = 'yes';

/// A foreground run stops after this; shorter than [runLockStaleAfterMs]
/// so the lock never goes stale while a run is alive.
const foregroundRunBudget = Duration(minutes: 15);

/// Turns settings into the background schedule (workmanager on the
/// phone, a fake in tests).
abstract interface class BackupScheduler {
  /// Schedules the periodic job for [settings], or cancels it when
  /// backup is off.
  Future<void> apply(BackupSettings settings);
}

/// Runs "Back up now" as a long-running job outside the app's isolate,
/// with a notification (D-038). Null in tests and off Android: the run
/// then happens in the controller.
abstract interface class ManualBackupLauncher {
  /// Queues the job (asks for the notification permission first).
  Future<void> start();

  /// True while the job is queued or running.
  Future<bool> isRunning();

  /// Calls [onProgress] with each progress map the job reports
  /// ([encodeWorkerProgress]).
  void listen(void Function(Map<String, Object?> progress) onProgress);
}

// ── Saved forms (JSON in app_values) ──────────────────────────────────

String encodeSettings(BackupSettings settings) => jsonEncode({
  'backup_on': settings.isBackupOn,
  'wifi_only': settings.isWifiOnly,
  'charging_only': settings.isChargingOnly,
  if (settings.chosenFolderIds case final folderIds?)
    'folder_ids': folderIds.toList()..sort(),
});

/// Defaults for anything missing or unreadable.
BackupSettings decodeSettings(String? text) {
  const defaults = BackupSettings();
  final json = _decodeObject(text);
  if (json == null) return defaults;
  bool readFlag(String name, bool fallback) {
    final value = json[name];
    return value is bool ? value : fallback;
  }

  final folderIds = json['folder_ids'];
  return BackupSettings(
    isBackupOn: readFlag('backup_on', defaults.isBackupOn),
    isWifiOnly: readFlag('wifi_only', defaults.isWifiOnly),
    isChargingOnly: readFlag('charging_only', defaults.isChargingOnly),
    chosenFolderIds: folderIds is List && folderIds.every((id) => id is String)
        ? {...folderIds.cast<String>()}
        : null,
  );
}

/// What the long backup job reports to the app (workmanager progress
/// data: ints and strings only).
Map<String, Object?> encodeWorkerProgress({
  required bool isDone,
  required DateTime startedAt,
  BackupProgress? progress,
  String? problem,
}) => {
  'state': isDone ? 'done' : 'running',
  'started_at_ms': startedAt.millisecondsSinceEpoch,
  'checked': progress?.itemsDone ?? 0,
  'total': progress?.itemsTotal ?? 0,
  'uploaded': progress?.filesUploaded ?? 0,
  'bytes': progress?.bytesUploaded ?? 0,
  'path': progress?.currentPath ?? '',
  'problem': ?problem,
};

/// The job's report: done (with an optional problem), or the live
/// numbers. Null for a map this app did not write.
({bool isDone, BackupLiveProgress? progress, String? problem})?
decodeWorkerProgress(Map<String, Object?> map) {
  final state = map['state'];
  if (state != 'running' && state != 'done') return null;
  int number(String name) => switch (map[name]) {
    final int value => value,
    _ => 0,
  };
  final problem = map['problem'];
  return (
    isDone: state == 'done',
    problem: problem is String ? problem : null,
    progress: BackupLiveProgress(
      startedAt: DateTime.fromMillisecondsSinceEpoch(number('started_at_ms')),
      itemsChecked: number('checked'),
      itemsTotal: number('total'),
      filesUploaded: number('uploaded'),
      bytesUploaded: number('bytes'),
      currentPath: switch (map['path']) {
        final String path => path,
        _ => '',
      },
    ),
  );
}

String encodeRunSummary(BackupRunSummary summary) => jsonEncode({
  'finished_at_ms': summary.finishedAt.millisecondsSinceEpoch,
  'files_uploaded': summary.filesUploaded,
  'files_already_backed_up': summary.filesAlreadyBackedUp,
  'files_failed': summary.filesFailed,
  'bytes_uploaded': summary.bytesUploaded,
  'problem': summary.problem,
});

BackupRunSummary? decodeRunSummary(String? text) {
  final json = _decodeObject(text);
  if (json == null) return null;
  try {
    return BackupRunSummary(
      finishedAt: DateTime.fromMillisecondsSinceEpoch(
        json['finished_at_ms']! as int,
      ),
      filesUploaded: json['files_uploaded']! as int,
      filesAlreadyBackedUp: json['files_already_backed_up']! as int,
      filesFailed: json['files_failed']! as int,
      bytesUploaded: json['bytes_uploaded']! as int,
      problem: json['problem'] as String?,
    );
  } on TypeError {
    return null;
  }
}

String encodeVerifySummary(VerifySummary summary) => jsonEncode({
  'finished_at_ms': summary.finishedAt.millisecondsSinceEpoch,
  'files_checked': summary.filesChecked,
  'files_wrong': summary.filesWrong,
  'problem': summary.problem,
});

VerifySummary? decodeVerifySummary(String? text) {
  final json = _decodeObject(text);
  if (json == null) return null;
  try {
    return VerifySummary(
      finishedAt: DateTime.fromMillisecondsSinceEpoch(
        json['finished_at_ms']! as int,
      ),
      filesChecked: json['files_checked']! as int,
      filesWrong: json['files_wrong']! as int,
      problem: json['problem'] as String?,
    );
  } on TypeError {
    return null;
  }
}

Map<String, Object?>? _decodeObject(String? text) {
  if (text == null) return null;
  try {
    final value = jsonDecode(text);
    return value is Map<String, Object?> ? value : null;
  } on FormatException {
    return null;
  }
}

/// The few numbers the Status screen shows.
BackupRunSummary summaryOfRun(BackupRunReport report) {
  final firstFailure = report.failures.firstOrNull;
  return BackupRunSummary(
    finishedAt: report.finishedAt,
    filesUploaded: report.filesUploaded,
    filesAlreadyBackedUp: report.filesAlreadyBackedUp,
    filesFailed: report.filesFailed,
    bytesUploaded: report.bytesUploaded,
    problem:
        report.problem ??
        (firstFailure == null
            ? null
            : 'First failure: ${firstFailure.remotePath}: '
                  '${firstFailure.message}'),
  );
}

/// "Wrong" = the server lacked chunks of it (now repaired).
VerifySummary summaryOfVerify(VerifyReport report) => VerifySummary(
  finishedAt: report.finishedAt,
  filesChecked: report.filesChecked,
  filesWrong: report.filesRepaired,
  problem:
      report.problem ??
      (report.filesFailed == 0
          ? null
          : '${report.filesFailed} files could not be checked'),
);

// ── Controller ────────────────────────────────────────────────────────

class BackupController extends ChangeNotifier {
  BackupController({
    required this.runner,
    required this.stateStore,
    required this.scheduler,
    this.manualLauncher,
    this.runBudget = foregroundRunBudget,
    this.log,
    DateTime Function()? clock,
    String? lockOwner,
  }) : clock = clock ?? DateTime.now,
       lockOwner = lockOwner ?? 'app-${DateTime.now().microsecondsSinceEpoch}';

  final BackupRunner runner;
  final BackupStateStore stateStore;
  final BackupScheduler scheduler;

  /// Null: "Back up now" runs here (tests, desktop).
  final ManualBackupLauncher? manualLauncher;
  final Duration runBudget;
  final DateTime Function() clock;

  /// Where a scheduling failure is noted (the session log); null = lost.
  final void Function(String note)? log;

  /// This app's name in the shared run lock.
  final String lockOwner;

  BackupActivity _activity = BackupActivity.idle;
  BackupSettings _settings = const BackupSettings();
  BackupRunReport? _lastReport;
  VerifyReport? _lastVerifyReport;
  BackupRunSummary? _lastRunSummary;
  VerifySummary? _lastVerifySummary;
  UploadCancel? _cancel;
  BackupLiveProgress? _progress;
  DateTime? _lastProgressNotifyAt;
  bool _isDisposed = false;

  /// Screen updates for live numbers are at most this often (a scan can
  /// look at thousands of photos a second).
  static const progressNotifyInterval = Duration(milliseconds: 250);

  /// A run may finish after the app dropped the controller: stay quiet.
  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cancel?.cancel();
    super.dispose();
  }

  BackupActivity get activity => _activity;
  BackupSettings get settings => _settings;
  BackupLiveProgress? get progress => _progress;

  /// The last foreground run of this app session; null before one.
  BackupRunReport? get lastReport => _lastReport;
  VerifyReport? get lastVerifyReport => _lastVerifyReport;

  /// The last run, by the app or the background job.
  BackupRunSummary? get lastRunSummary => _lastRunSummary;
  VerifySummary? get lastVerifySummary => _lastVerifySummary;

  /// Reads settings and the saved summaries, then schedules the
  /// background job for them.
  Future<void> start() async {
    _settings = decodeSettings(await stateStore.readValue(settingsValueName));
    _lastRunSummary = decodeRunSummary(
      await stateStore.readValue(lastRunValueName),
    );
    _lastVerifySummary = decodeVerifySummary(
      await stateStore.readValue(lastVerifyValueName),
    );
    final launcher = manualLauncher;
    if (launcher != null) {
      launcher.listen(onWorkerProgress);
      try {
        if (await launcher.isRunning() && _activity == BackupActivity.idle) {
          _activity = BackupActivity.backingUp;
        }
      } on Exception catch (error) {
        log?.call('backup job state unknown: $error');
      }
    }
    _notify();
    await _applySchedule();
  }

  /// A scheduling failure must not break the screens: it is logged.
  Future<void> _applySchedule() async {
    try {
      await scheduler.apply(_settings);
    } on Exception catch (error) {
      log?.call('background backup schedule failed: $error');
    }
  }

  /// Stops a running backup or verify after the current chunk: here, and
  /// in the long backup job through the shared store.
  Future<void> stop() async {
    _cancel?.cancel();
    final launcher = manualLauncher;
    if (launcher == null || _activity != BackupActivity.backingUp) return;
    await stateStore.writeValue(stopRequestedValueName, stopRequestedYes);
    // Android may have killed the job before its "done" report: then
    // nothing else would ever end "Backing up…".
    if (_cancel == null && !await launcher.isRunning()) {
      _activity = BackupActivity.idle;
      _progress = null;
      _notify();
    }
  }

  /// A progress map from the long backup job.
  Future<void> onWorkerProgress(Map<String, Object?> map) async {
    final report = decodeWorkerProgress(map);
    if (report == null) return;
    if (!report.isDone) {
      _activity = BackupActivity.backingUp;
      _progress = report.progress;
      _notify();
      return;
    }
    _activity = BackupActivity.idle;
    _progress = null;
    final saved = decodeRunSummary(
      await stateStore.readValue(lastRunValueName),
    );
    final problem = report.problem;
    _lastRunSummary = problem == null
        ? saved
        : BackupRunSummary(
            finishedAt: clock(),
            filesUploaded: 0,
            filesAlreadyBackedUp: 0,
            filesFailed: 0,
            bytesUploaded: 0,
            problem: problem,
          );
    _notify();
  }

  /// The phone's albums, Camera first, with the current choice.
  Future<List<BackupFolderChoice>> loadFolders() async {
    final access = await runner.mediaSource.requestAccess();
    if (!access.canRead) return const [];
    final folders = inBackupOrder(await runner.mediaSource.listFolders());
    final chosenIds = _settings.chosenFolderIds ?? defaultFolderIds(folders);
    return [
      for (final folder in folders)
        BackupFolderChoice(
          id: folder.id,
          name: folder.name,
          itemCount: folder.itemCount,
          isChosen: chosenIds.contains(folder.id),
        ),
    ];
  }

  void _onRunProgress(BackupProgress progress, DateTime startedAt) {
    _progress = BackupLiveProgress(
      startedAt: startedAt,
      itemsChecked: progress.itemsDone,
      itemsTotal: progress.itemsTotal,
      filesUploaded: progress.filesUploaded,
      bytesUploaded: progress.bytesUploaded,
      currentPath: progress.currentPath,
    );
    final now = clock();
    final last = _lastProgressNotifyAt;
    if (last == null || now.difference(last) >= progressNotifyInterval) {
      _lastProgressNotifyAt = now;
      _notify();
    }
  }

  Future<void> updateSettings(BackupSettings settings) async {
    _settings = settings;
    _notify();
    await stateStore.writeValue(settingsValueName, encodeSettings(settings));
    await _applySchedule();
  }

  /// Runs a backup now. Null when something is already running (here or
  /// in the background job); the summary then says so.
  Future<BackupRunReport?> runNow() async {
    void refused(String problem) => _lastRunSummary = BackupRunSummary(
      finishedAt: clock(),
      filesUploaded: 0,
      filesAlreadyBackedUp: 0,
      filesFailed: 0,
      bytesUploaded: 0,
      problem: problem,
    );
    final launcher = manualLauncher;
    if (launcher != null) {
      await _launch(launcher, onRefused: refused);
      return null;
    }
    final startedAt = clock();
    final report = await _exclusive(
      BackupActivity.backingUp,
      (cancel) => runner.runOnce(
        folderIds: _settings.chosenFolderIds,
        budget: runBudget,
        cancel: cancel,
        onProgress: (progress) => _onRunProgress(progress, startedAt),
      ),
      onRefused: refused,
    );
    if (report != null) {
      _lastReport = report;
      _lastRunSummary = summaryOfRun(report);
      await stateStore.writeValue(
        lastRunValueName,
        encodeRunSummary(_lastRunSummary!),
      );
    }
    _notify();
    return report;
  }

  /// "Verify backup" (M6): offers every backed-up file again. Null when
  /// something is already running.
  Future<VerifyReport?> verifyAll() async {
    final startedAt = clock();
    final report = await _exclusive(
      BackupActivity.verifying,
      (cancel) => runner.verifyAll(
        cancel: cancel,
        onProgress: (progress) => _onRunProgress(progress, startedAt),
      ),
      onRefused: (problem) => _lastVerifySummary = VerifySummary(
        finishedAt: DateTime.now(),
        filesChecked: 0,
        filesWrong: 0,
        problem: problem,
      ),
    );
    if (report != null) {
      _lastVerifyReport = report;
      _lastVerifySummary = summaryOfVerify(report);
      await stateStore.writeValue(
        lastVerifyValueName,
        encodeVerifySummary(_lastVerifySummary!),
      );
    }
    _notify();
    return report;
  }

  static const busyText = 'A backup is already running.';

  /// Queues the long backup job; the screens follow it through
  /// [onWorkerProgress].
  Future<void> _launch(
    ManualBackupLauncher launcher, {
    required void Function(String problem) onRefused,
  }) async {
    if (_activity != BackupActivity.idle) {
      onRefused(busyText);
      _notify();
      return;
    }
    _activity = BackupActivity.backingUp;
    _progress = null;
    _notify();
    try {
      await stateStore.writeValue(stopRequestedValueName, 'no');
      await launcher.start();
    } on Exception catch (error) {
      _activity = BackupActivity.idle;
      onRefused('Could not start the backup: $error');
    }
    _notify();
  }

  /// Sets [activity] at once (before any await), takes the shared run
  /// lock, runs [work], and frees both. Busy or failed: [onRefused] gets
  /// the reason and the result is null.
  Future<T?> _exclusive<T>(
    BackupActivity activity,
    Future<T> Function(UploadCancel cancel) work, {
    required void Function(String problem) onRefused,
  }) async {
    if (_activity != BackupActivity.idle) {
      onRefused(busyText);
      return null;
    }
    _activity = activity;
    final cancel = _cancel = UploadCancel();
    _notify();
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (!await stateStore.claimRunLock(lockOwner, nowMs)) {
        onRefused('$busyText (in the background)');
        return null;
      }
      try {
        return await work(cancel);
      } on Exception catch (error) {
        // A plugin or disk error outside the per-item handling.
        onRefused('Stopped by an error: $error');
        return null;
      } finally {
        await stateStore.releaseRunLock(lockOwner);
      }
    } finally {
      _cancel = null;
      _progress = null;
      _activity = BackupActivity.idle;
    }
  }
}

// ── Adapter for the screens ───────────────────────────────────────────

/// [BackupController] as the screens see it. Forwards every controller
/// change to its own listeners.
class BackupControllerStatusSource extends ChangeNotifier
    implements BackupStatusSource {
  BackupControllerStatusSource(this.controller) {
    controller.addListener(notifyListeners);
  }

  final BackupController controller;

  @override
  BackupActivity get activity => controller.activity;

  @override
  BackupLiveProgress? get progress => controller.progress;

  @override
  Future<void> stop() => controller.stop();

  @override
  Future<List<BackupFolderChoice>> loadFolders() => controller.loadFolders();

  @override
  BackupRunSummary? get lastRun => controller.lastRunSummary;

  @override
  VerifySummary? get lastVerify => controller.lastVerifySummary;

  @override
  BackupSettings get settings => controller.settings;

  /// Returns once the run has started (activity is already
  /// [BackupActivity.backingUp]) or was refused.
  @override
  Future<void> runNow() async => unawaited(controller.runNow());

  @override
  Future<void> verifyAll() async => unawaited(controller.verifyAll());

  @override
  Future<void> updateSettings(BackupSettings settings) =>
      controller.updateSettings(settings);

  @override
  void dispose() {
    controller.removeListener(notifyListeners);
    super.dispose();
  }
}
