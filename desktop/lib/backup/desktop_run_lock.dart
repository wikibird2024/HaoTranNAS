/// The run lock on the PC (D-033 lock, shared store): the app names it
/// after its process, so a lock left by a closed or crashed app is freed
/// at the next start instead of blocking backups for 20 minutes.
///
/// ```
///  owner = desktop-<pid>
///  start: lock owner desktop-<pid> and /proc/<pid> gone ─► release it
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:convert';
import 'dart:io';

import 'package:haotrannas_client/backup/backup_state_store.dart';

const _ownerPrefix = 'desktop-';

/// This app's name in the run lock.
String desktopLockOwner([int? processId]) => '$_ownerPrefix${processId ?? pid}';

/// Whether process [processId] still runs (Linux: `/proc/<pid>`).
bool isProcessAlive(int processId) =>
    Directory('/proc/$processId').existsSync();

/// Releases the run lock when a PC app that is no longer running holds
/// it. Returns the freed owner, or null.
Future<String?> releaseDeadDesktopLock(
  BackupStateStore store, {
  bool Function(int processId) isAlive = isProcessAlive,
}) async {
  final String? owner;
  try {
    final lockText = await store.readValue(runLockValueName);
    owner = lockText == null
        ? null
        : (jsonDecode(lockText) as Map<String, Object?>)['owner'] as String?;
  } on Object {
    return null;
  }
  if (owner == null || !owner.startsWith(_ownerPrefix)) return null;
  final processId = int.tryParse(owner.substring(_ownerPrefix.length));
  if (processId == null || isAlive(processId)) return null;
  await store.releaseRunLock(owner);
  return owner;
}
