/// The PC's automatic backup: a timer while the app is open (D-039; no
/// service and no tray yet).
///
/// ```
///  settings.isBackupOn ─► first run after [firstRunDelay], then every [interval]
///  backup off ─────────► timers cancelled
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:async';

import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';

class TimerBackupScheduler implements BackupScheduler {
  TimerBackupScheduler({
    this.interval = const Duration(hours: 1),
    this.firstRunDelay = const Duration(seconds: 30),
  });

  final Duration interval;

  /// The first run waits a little so the app starts quietly.
  final Duration firstRunDelay;

  /// Set once the controller exists: starts a run (a busy controller
  /// refuses it on its own).
  void Function()? onDue;

  Timer? _firstRun;
  Timer? _everyInterval;

  bool get isScheduled => _everyInterval != null;

  @override
  Future<void> apply(BackupSettings settings) async {
    cancel();
    if (!settings.isBackupOn) return;
    _firstRun = Timer(firstRunDelay, () => onDue?.call());
    _everyInterval = Timer.periodic(interval, (_) => onDue?.call());
  }

  void cancel() {
    _firstRun?.cancel();
    _everyInterval?.cancel();
    _firstRun = null;
    _everyInterval = null;
  }
}
