/// What the Status and Settings screens need from the backup side
/// (`lib/backup/`, built separately). The screens only see this
/// interface; an adapter over the real `BackupController` implements it.
///
/// ```
///  BackupController (lib/backup) ──adapter──► BackupStatusSource ──► Backup tab, Settings, Folders
///     runNow/stop/verifyAll/progress/folders/settings     notifyListeners() on every change
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
    this.filesLeft = 0,
    this.problem,
  });

  final DateTime finishedAt;
  final int filesUploaded;

  /// Offered, but the server had the same content already.
  final int filesAlreadyBackedUp;
  final int filesFailed;
  final int bytesUploaded;

  /// New or changed files the run found but did not reach (time up,
  /// Stop, link lost). A lower bound: a run that stopped mid-scan never
  /// saw the rest of the library.
  final int filesLeft;

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

/// Live numbers of the running backup or check.
final class BackupLiveProgress {
  const BackupLiveProgress({
    required this.startedAt,
    required this.itemsChecked,
    required this.itemsTotal,
    required this.filesUploaded,
    required this.bytesUploaded,
    required this.currentPath,
  });

  final DateTime startedAt;

  /// Photos looked at (backup) or files checked (verify) so far.
  final int itemsChecked;

  /// About how many there are in all (the library can change meanwhile).
  final int itemsTotal;
  final int filesUploaded;
  final int bytesUploaded;

  /// The photo being looked at or sent; empty before the first.
  final String currentPath;

  /// 0..1 for the progress bar; null while the total is unknown.
  double? get fraction =>
      itemsTotal <= 0 ? null : (itemsChecked / itemsTotal).clamp(0.0, 1.0);

  /// Average upload speed since [startedAt].
  double bytesPerSecond(DateTime now) {
    final seconds = now.difference(startedAt).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : bytesUploaded / seconds;
  }
}

/// One phone album and whether it is backed up.
final class BackupFolderChoice {
  const BackupFolderChoice({
    required this.id,
    required this.name,
    required this.itemCount,
    required this.isChosen,
  });

  final String id;
  final String name;
  final int itemCount;
  final bool isChosen;
}

/// The user's backup choices.
final class BackupSettings {
  const BackupSettings({
    this.isBackupOn = true,
    this.isWifiOnly = true,
    this.isChargingOnly = false,
    this.chosenFolderIds,
    this.chosenFolderNames,
  });

  /// Automatic background backup runs at all.
  final bool isBackupOn;

  /// Runs only on Wi-Fi (never on mobile data).
  final bool isWifiOnly;

  /// Runs only while the phone is charging.
  final bool isChargingOnly;

  /// Albums to back up; null = never chosen: the Camera album (D-037).
  final Set<String>? chosenFolderIds;

  /// The chosen albums' names, saved with the ids so the Backup tab can
  /// show them without listing the albums (which asks for photo access).
  /// For display only; null = not known (settings saved before D-042).
  final List<String>? chosenFolderNames;

  BackupSettings copyWith({
    bool? isBackupOn,
    bool? isWifiOnly,
    bool? isChargingOnly,
    Set<String>? chosenFolderIds,
    List<String>? chosenFolderNames,
  }) => BackupSettings(
    isBackupOn: isBackupOn ?? this.isBackupOn,
    isWifiOnly: isWifiOnly ?? this.isWifiOnly,
    isChargingOnly: isChargingOnly ?? this.isChargingOnly,
    chosenFolderIds: chosenFolderIds ?? this.chosenFolderIds,
    chosenFolderNames: chosenFolderNames ?? this.chosenFolderNames,
  );
}

/// The backup side as the screens see it. Calls [notifyListeners] (as a
/// [Listenable]) whenever any getter's value changes.
abstract interface class BackupStatusSource implements Listenable {
  BackupActivity get activity;

  /// Numbers of the running backup or check; null when idle or before
  /// the first number arrives.
  BackupLiveProgress? get progress;

  /// Null before the first run.
  BackupRunSummary? get lastRun;

  /// Null before the first check.
  VerifySummary? get lastVerify;

  BackupSettings get settings;

  /// Starts a backup run now (a long-running job with a notification on
  /// Android, D-038). Returns when it has started or was refused;
  /// progress comes through [activity], [progress] and [lastRun].
  Future<void> runNow();

  /// Stops the running backup or check after the current chunk.
  Future<void> stop();

  /// The phone's albums with their choice (asks for photo access first;
  /// empty without it).
  Future<List<BackupFolderChoice>> loadFolders();

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
  BackupLiveProgress? get progress => null;

  @override
  Future<void> stop() async {}

  @override
  Future<List<BackupFolderChoice>> loadFolders() async => const [];

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
