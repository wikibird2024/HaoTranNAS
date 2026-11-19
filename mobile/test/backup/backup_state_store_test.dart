// Both stores pass the same checks; the SQLite one runs on the host
// through sqflite_common_ffi (system libsqlite3).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/backup/backup_state_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const photo = BackupRecord(
  mediaId: '1001',
  remotePath: 'DCIM/Camera/IMG_0001.jpg',
  sizeBytes: 3145745,
  modifiedTimeMs: 1763450000000,
);

void storeContract(Future<BackupStateStore> Function() openStore) {
  late BackupStateStore store;

  setUp(() async => store = await openStore());
  tearDown(() => store.close());

  test('empty at first', () async {
    expect(await store.loadAll(), isEmpty);
    expect(await store.readValue('settings'), isNull);
  });

  test('put inserts, put again replaces', () async {
    await store.put(photo);
    expect(await store.loadAll(), {'1001': photo});

    final backedUp = photo.copyWith(
      versionId: 7,
      backedUpAtMs: 1763450001000,
      lastVerifiedAtMs: 1763450002000,
    );
    await store.put(backedUp);
    final records = await store.loadAll();
    expect(records, {'1001': backedUp});
    expect(records['1001']!.isBackedUp, isTrue);
  });

  test('every column round-trips, nulls too', () async {
    const full = BackupRecord(
      mediaId: 'id with spaces',
      remotePath: 'Pictures/Ünïcode/ảnh.heic',
      sizeBytes: 0,
      modifiedTimeMs: -1,
      fileSha256Hex:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      versionId: 9007199254740993,
      backedUpAtMs: 1,
      lastVerifiedAtMs: 2,
      lastError: 'server error DISK_FULL',
    );
    await store.put(full);
    await store.put(photo);
    expect(await store.loadAll(), {full.mediaId: full, photo.mediaId: photo});
  });

  test('copyWith clears or keeps the error', () {
    final failed = photo.copyWith(lastError: 'boom');
    expect(failed.lastError, 'boom');
    expect(failed.copyWith(versionId: 3).lastError, 'boom');
    expect(failed.copyWith(clearError: true).lastError, isNull);
  });

  test('values: write, overwrite, read', () async {
    await store.writeValue('settings', '{"a":1}');
    await store.writeValue('settings', '{"a":2}');
    await store.writeValue('last_run', 'x');
    expect(await store.readValue('settings'), '{"a":2}');
    expect(await store.readValue('last_run'), 'x');
  });

  test('run lock: one owner at a time, stale lock taken over', () async {
    const startMs = 1763450000000;
    expect(await store.claimRunLock('app', startMs), isTrue);
    expect(
      await store.claimRunLock('app', startMs + 1000),
      isTrue,
      reason: 'the holder refreshes',
    );
    expect(await store.claimRunLock('background', startMs + 2000), isFalse);

    await store.releaseRunLock('background'); // not the holder: no effect
    expect(await store.claimRunLock('background', startMs + 3000), isFalse);

    await store.releaseRunLock('app');
    expect(await store.claimRunLock('background', startMs + 4000), isTrue);

    final staleMs = startMs + 4000 + runLockStaleAfterMs + 1;
    expect(
      await store.claimRunLock('app', staleMs),
      isTrue,
      reason: 'holder died: lock is stale',
    );
  });
}

void main() {
  group('MemoryBackupStateStore', () {
    storeContract(() async => MemoryBackupStateStore());
  });

  group('SqfliteBackupStateStore (ffi)', () {
    late Directory folder;

    setUpAll(sqfliteFfiInit);
    setUp(() => folder = Directory.systemTemp.createTempSync('backup_db'));
    tearDown(() => folder.deleteSync(recursive: true));

    storeContract(
      () => SqfliteBackupStateStore.open(
        '${folder.path}/${SqfliteBackupStateStore.fileName}',
        factory: databaseFactoryFfi,
      ),
    );

    test('data survives close and reopen; schema as specified', () async {
      final path = '${folder.path}/reopen.db';
      final first = await SqfliteBackupStateStore.open(
        path,
        factory: databaseFactoryFfi,
      );
      await first.put(photo.copyWith(versionId: 5));
      await first.writeValue('settings', 's');
      await first.close();

      final second = await SqfliteBackupStateStore.open(
        path,
        factory: databaseFactoryFfi,
      );
      expect((await second.loadAll())['1001']!.versionId, 5);
      expect(await second.readValue('settings'), 's');
      final columns = await second.database.rawQuery(
        'PRAGMA table_info(items)',
      );
      expect(
        [for (final column in columns) column['name']],
        [
          'media_id',
          'remote_path',
          'size_bytes',
          'modified_time_ms',
          'file_sha256',
          'version_id',
          'backed_up_at_ms',
          'last_verified_at_ms',
          'last_error',
        ],
      );
      await second.close();
    });
  });
}
