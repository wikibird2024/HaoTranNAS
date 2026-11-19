/// The app's handle on backup: run now, verify, settings, last results;
/// and the adapter the screens see ([BackupControllerStatusSource]).
///
/// ```
///  Status/Settings ─► BackupControllerStatusSource ─► BackupController
///                       (BackupStatusSource)            │ runNow / verifyAll ─► BackupRunner
///                                                       │ updateSettings ─► store + BackupScheduler
///                                                       ▼
///                            SqfliteBackupStateStore: settings, last_run, last_verify, run_lock
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
import '../ui/backup_status_source.dart';
import 'backup_runner.dart';
import 'backup_state_store.dart';

/// Names in the store's `app_values` table.
const settingsValueName = 'settings';
const lastRunValueName = 'last_run';
const lastVerifyValueName = 'last_verify';

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

// ── Saved forms (JSON in app_values) ──────────────────────────────────

String encodeSettings(BackupSettings settings) => jsonEncode({
  'backup_on': settings.isBackupOn,
  'wifi_only': settings.isWifiOnly,
  'charging_only': settings.isChargingOnly,
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

  return BackupSettings(
    isBackupOn: readFlag('backup_on', defaults.isBackupOn),
    isWifiOnly: readFlag('wifi_only', defaults.isWifiOnly),
    isChargingOnly: readFlag('charging_only', defaults.isChargingOnly),
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
    this.runBudget = foregroundRunBudget,
    this.log,
    String? lockOwner,
  }) : lockOwner = lockOwner ?? 'app-${DateTime.now().microsecondsSinceEpoch}';

  final BackupRunner runner;
  final BackupStateStore stateStore;
  final BackupScheduler scheduler;
  final Duration runBudget;

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
  bool _isDisposed = false;

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

  /// Stops a running backup or verify after the current chunk.
  void stop() => _cancel?.cancel();

  Future<void> updateSettings(BackupSettings settings) async {
    _settings = settings;
    _notify();
    await stateStore.writeValue(settingsValueName, encodeSettings(settings));
    await _applySchedule();
  }

  /// Runs a backup now. Null when something is already running (here or
  /// in the background job); the summary then says so.
  Future<BackupRunReport?> runNow() async {
    final report = await _exclusive(
      BackupActivity.backingUp,
      (cancel) => runner.runOnce(budget: runBudget, cancel: cancel),
      onRefused: (problem) => _lastRunSummary = BackupRunSummary(
        finishedAt: DateTime.now(),
        filesUploaded: 0,
        filesAlreadyBackedUp: 0,
        filesFailed: 0,
        bytesUploaded: 0,
        problem: problem,
      ),
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
    final report = await _exclusive(
      BackupActivity.verifying,
      (cancel) => runner.verifyAll(cancel: cancel),
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
