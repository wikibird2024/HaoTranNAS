/// The PC app's providers: the shared ones (`client_providers.dart` in
/// dart_client, re-exported here) plus the PC parts: folder backup on a
/// timer, the NAS admin connection, the restore folder.
///
/// ```
///  main() ─► overrides: identity store, restore folder, client software,
///            backup source (FolderMediaSource + TimerBackupScheduler),
///            saved admin target
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/app/client_providers.dart';
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';

import '../backup/desktop_run_lock.dart';
import '../backup/folder_media_source.dart';
import '../backup/timer_backup_scheduler.dart';

export 'package:haotrannas_client/app/client_providers.dart';

/// Sent in Hello (`client_software`).
const appClientSoftware = 'haotrannas-desktop 0.1.0';

/// A PC run may take long: the first backup of a big folder.
const desktopRunBudget = Duration(hours: 6);

/// How often the automatic backup runs while the app is open.
const desktopBackupInterval = Duration(hours: 1);

/// The real backup side over [store]; `main()` overrides
/// [backupStatusSourceProvider] with it.
BackupStatusSource desktopBackupStatusSource(Ref ref, BackupStateStore store) {
  final log = ref.read(sessionLogProvider);
  final scheduler = TimerBackupScheduler(interval: desktopBackupInterval);
  late final BackupController controller;
  controller = BackupController(
    runner: BackupRunner(
      mediaSource: FolderMediaSource(
        chosenFolderPaths: () => controller.settings.chosenFolderIds ?? {},
        onSkipped: log.note,
      ),
      stateStore: store,
      connect: () => connectForBackup(ref),
    ),
    stateStore: store,
    scheduler: scheduler,
    runBudget: desktopRunBudget,
    log: log.note,
    lockOwner: desktopLockOwner(),
  );
  scheduler.onDue = () {
    // Nothing chosen yet: stay quiet instead of saving a "no folders" run.
    if ((controller.settings.chosenFolderIds ?? {}).isEmpty) return;
    unawaited(controller.runNow());
  };
  final source = BackupControllerStatusSource(controller);
  unawaited(() async {
    final freed = await releaseDeadDesktopLock(store);
    if (freed != null) log.note('freed the run lock of a closed app ($freed)');
    await controller.start();
  }());
  ref.onDispose(() {
    scheduler.cancel();
    unawaited(controller.stop());
    source.dispose();
    controller.dispose();
  });
  return source;
}
