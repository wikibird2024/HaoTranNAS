/// What the Status and Settings screens need from the backup side
/// (`lib/backup/`, built separately). The screens only see this
/// interface; an adapter over the real `BackupController` implements it.
///
/// ```
///  BackupController (lib/backup) ──adapter──► BackupStatusSource ──► Status, Settings
///     start/stop/runNow/verifyAll/lastReport/settings      notifyListeners() on every change
/// ```
///
/// Until the adapter exists the app uses [BackupNotConnected]. Author:
/// Hao Tran.
library;

import 'package:flutter/foundation.dart';

/// What the backup side is doing right now.
enum BackupActivity { idle, backingUp, verifying }

/// How the last backup run ended, in a few numbers.
final class BackupRunSummary {
  const BackupRunSummary({
    required this.finishedAt,
    required this.filesUploaded,
    required this.filesAlreadyBackedUp,
    required this.filesFailed,
    required this.bytesUploaded,
    this.problem,
  });

  final DateTime finishedAt;
  final int filesUploaded;

  /// Offered, but the server had the same content already.
  final int filesAlreadyBackedUp;
  final int filesFailed;
  final int bytesUploaded;

  /// Why the run stopped early (no Wi-Fi, server offline), or null.
  final String? problem;
}

/// How the last "verify backup" ended.
final class VerifySummary {
  const VerifySummary({
    required this.finishedAt,
    required this.filesChecked,
    required this.filesWrong,
    this.problem,
  });

  final DateTime finishedAt;
  final int filesChecked;

  /// Missing on the server, or different from the phone's file.
  final int filesWrong;

  /// Why the check stopped early, or null.
  final String? problem;
}

/// The user's backup choices.
final class BackupSettings {
  const BackupSettings({
    this.isBackupOn = true,
    this.isWifiOnly = true,
    this.isChargingOnly = false,
  });

  /// Automatic background backup runs at all.
  final bool isBackupOn;

  /// Runs only on Wi-Fi (never on mobile data).
  final bool isWifiOnly;

  /// Runs only while the phone is charging.
  final bool isChargingOnly;

  BackupSettings copyWith({
    bool? isBackupOn,
    bool? isWifiOnly,
    bool? isChargingOnly,
  }) => BackupSettings(
    isBackupOn: isBackupOn ?? this.isBackupOn,
    isWifiOnly: isWifiOnly ?? this.isWifiOnly,
    isChargingOnly: isChargingOnly ?? this.isChargingOnly,
  );
}

/// The backup side as the screens see it. Calls [notifyListeners] (as a
/// [Listenable]) whenever any getter's value changes.
abstract interface class BackupStatusSource implements Listenable {
  BackupActivity get activity;

  /// Null before the first run.
  BackupRunSummary? get lastRun;

  /// Null before the first check.
  VerifySummary? get lastVerify;

  BackupSettings get settings;

  /// Starts a backup run now (foreground). Returns when it has started
  /// or was refused; progress comes through [activity] and [lastRun].
  Future<void> runNow();

  /// Re-offers every backed-up file so the server asks again for any
  /// missing or bad chunk (spec §8 repair note); the result comes through
  /// [lastVerify].
  Future<void> verifyAll();

  /// Saves [settings] and reschedules the background job.
  Future<void> updateSettings(BackupSettings settings);
}

/// Placeholder until `lib/backup/` is connected: keeps settings in
/// memory and answers every action with "not built yet".
class BackupNotConnected extends ChangeNotifier implements BackupStatusSource {
  static const notBuiltText = 'Backup is not built into this app yet.';

  BackupSettings _settings = const BackupSettings();
  BackupRunSummary? _lastRun;

  @override
  BackupActivity get activity => BackupActivity.idle;

  @override
  BackupRunSummary? get lastRun => _lastRun;

  @override
  VerifySummary? get lastVerify => null;

  @override
  BackupSettings get settings => _settings;

  @override
  Future<void> runNow() async {
    _lastRun = BackupRunSummary(
      finishedAt: DateTime.now(),
      filesUploaded: 0,
      filesAlreadyBackedUp: 0,
      filesFailed: 0,
      bytesUploaded: 0,
      problem: notBuiltText,
    );
    notifyListeners();
  }

  @override
  Future<void> verifyAll() => runNow();

  @override
  Future<void> updateSettings(BackupSettings settings) async {
    _settings = settings;
    notifyListeners();
  }
}
