// A run lock left by a closed PC app is freed at start; a live one, a
// phone job's lock or a damaged value are left alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_desktop/backup/desktop_run_lock.dart';

void main() {
  late MemoryBackupStateStore store;

  setUp(() => store = MemoryBackupStateStore());

  test('owner name carries the process id', () {
    expect(desktopLockOwner(42), 'desktop-42');
  });

  test('a dead PC app\'s lock is released', () async {
    await store.claimRunLock(desktopLockOwner(42), 1000);
    final freed = await releaseDeadDesktopLock(store, isAlive: (_) => false);
    expect(freed, 'desktop-42');
    expect(await store.readValue(runLockValueName), isNull);
    expect(await store.claimRunLock(desktopLockOwner(7), 1001), isTrue);
  });

  test('a running app, a phone job, no lock, damaged text: kept', () async {
    await store.claimRunLock(desktopLockOwner(42), 1000);
    expect(await releaseDeadDesktopLock(store, isAlive: (_) => true), isNull);
    expect(await store.readValue(runLockValueName), isNotNull);

    store = MemoryBackupStateStore();
    await store.claimRunLock('app-123', 1000);
    expect(await releaseDeadDesktopLock(store, isAlive: (_) => false), isNull);

    store = MemoryBackupStateStore();
    expect(await releaseDeadDesktopLock(store, isAlive: (_) => false), isNull);
    await store.writeValue(runLockValueName, '{');
    expect(await releaseDeadDesktopLock(store, isAlive: (_) => false), isNull);
  });

  test('this process is alive', () {
    expect(isProcessAlive(int.parse(desktopLockOwner().substring(8))), isTrue);
  });
}
