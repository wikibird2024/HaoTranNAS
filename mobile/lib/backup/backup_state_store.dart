/// The phone's record of what is backed up (one row per media item), plus
/// a few saved values (settings, last run summaries, the run lock).
///
/// ```
///  items       media_id → remote path, size, mtime, version id, errors
///  app_values  name → text ('settings', 'last_run', 'last_verify', 'run_lock')
/// ```
///
/// [SqfliteBackupStateStore] is the real one (one SQLite file shared by
/// the app and the background job); [MemoryBackupStateStore] is for
/// tests. Author: Hao Tran.
library;

import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'media_source.dart';

/// What the phone knows about one media item.
final class BackupRecord {
  const BackupRecord({
    required this.mediaId,
    required this.remotePath,
    required this.sizeBytes,
    required this.modifiedTimeMs,
    this.fileSha256Hex,
    this.versionId,
    this.backedUpAtMs,
    this.lastVerifiedAtMs,
    this.lastError,
  });

  final String mediaId;

  /// Path, size and time of the copy that [versionId] holds (or of the
  /// failed attempt, when [versionId] is null).
  final String remotePath;
  final int sizeBytes;
  final int modifiedTimeMs;

  /// Whole-file SHA-256, lowercase hex; null while not known.
  final String? fileSha256Hex;

  /// The server's version id; null = never backed up.
  final int? versionId;
  final int? backedUpAtMs;
  final int? lastVerifiedAtMs;

  /// Why the last attempt failed; null after a success.
  final String? lastError;

  bool get isBackedUp => versionId != null;

  /// True when [item] still is exactly the copy [versionId] holds.
  bool matches(MediaItem item) =>
      remotePath == item.relativePath &&
      sizeBytes == item.sizeBytes &&
      modifiedTimeMs == item.modifiedTimeMs;

  BackupRecord copyWith({
    int? versionId,
    int? backedUpAtMs,
    int? lastVerifiedAtMs,
    String? lastError,
    bool clearError = false,
  }) => BackupRecord(
    mediaId: mediaId,
    remotePath: remotePath,
    sizeBytes: sizeBytes,
    modifiedTimeMs: modifiedTimeMs,
    fileSha256Hex: fileSha256Hex,
    versionId: versionId ?? this.versionId,
    backedUpAtMs: backedUpAtMs ?? this.backedUpAtMs,
    lastVerifiedAtMs: lastVerifiedAtMs ?? this.lastVerifiedAtMs,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  Map<String, Object?> toRow() => {
    'media_id': mediaId,
    'remote_path': remotePath,
    'size_bytes': sizeBytes,
    'modified_time_ms': modifiedTimeMs,
    'file_sha256': fileSha256Hex,
    'version_id': versionId,
    'backed_up_at_ms': backedUpAtMs,
    'last_verified_at_ms': lastVerifiedAtMs,
    'last_error': lastError,
  };

  static BackupRecord fromRow(Map<String, Object?> row) => BackupRecord(
    mediaId: row['media_id']! as String,
    remotePath: row['remote_path']! as String,
    sizeBytes: row['size_bytes']! as int,
    modifiedTimeMs: row['modified_time_ms']! as int,
    fileSha256Hex: row['file_sha256'] as String?,
    versionId: row['version_id'] as int?,
    backedUpAtMs: row['backed_up_at_ms'] as int?,
    lastVerifiedAtMs: row['last_verified_at_ms'] as int?,
    lastError: row['last_error'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is BackupRecord && _sameMaps(other.toRow(), toRow());

  @override
  int get hashCode => Object.hashAll(toRow().values);

  @override
  String toString() => 'BackupRecord(${toRow()})';
}

bool _sameMaps(Map<String, Object?> first, Map<String, Object?> second) =>
    first.length == second.length &&
    first.keys.every((key) => first[key] == second[key]);

/// Only one backup run at a time (app and background job share the DB).
/// A lock older than this is taken over (its holder died).
const int runLockStaleAfterMs = 20 * 60 * 1000;

abstract interface class BackupStateStore {
  /// Every record, by media id.
  Future<Map<String, BackupRecord>> loadAll();

  /// Inserts or replaces the record for `record.mediaId`.
  Future<void> put(BackupRecord record);

  Future<String?> readValue(String name);
  Future<void> writeValue(String name, String value);

  /// Takes the run lock for [owner], or refreshes it when [owner] holds
  /// it. False while another owner holds a lock younger than
  /// [runLockStaleAfterMs].
  Future<bool> claimRunLock(String owner, int nowMs);

  /// Frees the lock if [owner] holds it.
  Future<void> releaseRunLock(String owner);

  Future<void> close();
}

const _runLockName = 'run_lock';

/// The lock decision, shared by both stores. Pure.
bool _canTakeLock(String? lockText, String owner, int nowMs) {
  if (lockText == null) return true;
  try {
    final lock = jsonDecode(lockText) as Map<String, Object?>;
    if (lock['owner'] == owner) return true;
    return nowMs - (lock['at_ms']! as int) > runLockStaleAfterMs;
  } on Object {
    return true; // unreadable lock = no lock
  }
}

String _lockText(String owner, int nowMs) =>
    jsonEncode({'owner': owner, 'at_ms': nowMs});

class MemoryBackupStateStore implements BackupStateStore {
  final records = <String, BackupRecord>{};
  final values = <String, String>{};

  @override
  Future<Map<String, BackupRecord>> loadAll() async => Map.of(records);

  @override
  Future<void> put(BackupRecord record) async =>
      records[record.mediaId] = record;

  @override
  Future<String?> readValue(String name) async => values[name];

  @override
  Future<void> writeValue(String name, String value) async =>
      values[name] = value;

  @override
  Future<bool> claimRunLock(String owner, int nowMs) async {
    if (!_canTakeLock(values[_runLockName], owner, nowMs)) return false;
    values[_runLockName] = _lockText(owner, nowMs);
    return true;
  }

  @override
  Future<void> releaseRunLock(String owner) async {
    if (_lockOwner(values[_runLockName]) == owner) values.remove(_runLockName);
  }

  @override
  Future<void> close() async {}
}

String? _lockOwner(String? lockText) {
  if (lockText == null) return null;
  try {
    return (jsonDecode(lockText) as Map<String, Object?>)['owner'] as String?;
  } on Object {
    return null;
  }
}

class SqfliteBackupStateStore implements BackupStateStore {
  SqfliteBackupStateStore._(this.database);

  static const fileName = 'backup_state.db';
  static const schemaVersion = 1;

  final Database database;

  /// The app's store in the support folder (same place as the identity),
  /// opened by both the app and the background job.
  static Future<SqfliteBackupStateStore> openForApp() async {
    final folder = await getApplicationSupportDirectory();
    return open('${folder.path}/$fileName');
  }

  /// Opens (and creates) the database at [path]; tests pass the ffi
  /// [factory].
  static Future<SqfliteBackupStateStore> open(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final database = await (factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE items (
              media_id TEXT PRIMARY KEY NOT NULL,
              remote_path TEXT NOT NULL,
              size_bytes INTEGER NOT NULL,
              modified_time_ms INTEGER NOT NULL,
              file_sha256 TEXT,
              version_id INTEGER,
              backed_up_at_ms INTEGER,
              last_verified_at_ms INTEGER,
              last_error TEXT
            )''');
          await database.execute('''
            CREATE TABLE app_values (
              name TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
            )''');
        },
      ),
    );
    return SqfliteBackupStateStore._(database);
  }

  @override
  Future<Map<String, BackupRecord>> loadAll() async {
    final rows = await database.query('items');
    return {
      for (final row in rows)
        row['media_id']! as String: BackupRecord.fromRow(row),
    };
  }

  @override
  Future<void> put(BackupRecord record) => database.insert(
    'items',
    record.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<String?> readValue(String name) => _readValue(database, name);

  static Future<String?> _readValue(
    DatabaseExecutor executor,
    String name,
  ) async {
    final rows = await executor.query(
      'app_values',
      columns: ['value'],
      where: 'name = ?',
      whereArgs: [name],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> writeValue(String name, String value) =>
      _writeValue(database, name, value);

  static Future<void> _writeValue(
    DatabaseExecutor executor,
    String name,
    String value,
  ) => executor.insert('app_values', {
    'name': name,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<bool> claimRunLock(String owner, int nowMs) =>
      database.transaction((transaction) async {
        final lockText = await _readValue(transaction, _runLockName);
        if (!_canTakeLock(lockText, owner, nowMs)) return false;
        await _writeValue(transaction, _runLockName, _lockText(owner, nowMs));
        return true;
      });

  @override
  Future<void> releaseRunLock(String owner) =>
      database.transaction((transaction) async {
        final lockText = await _readValue(transaction, _runLockName);
        if (_lockOwner(lockText) != owner) return;
        await transaction.delete(
          'app_values',
          where: 'name = ?',
          whereArgs: [_runLockName],
        );
      });

  @override
  Future<void> close() => database.close();
}
