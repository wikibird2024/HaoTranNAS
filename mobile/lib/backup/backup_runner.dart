/// One backup run, and "verify backup" (M6).
///
/// ```
///  runOnce
///   requestAccess ─► none → stop (noMediaAccess)
///   scan all items ─► pick new/changed (no record, never backed up,
///                     or path/size/mtime differ) ─► newest first
///   nothing to do → stop (no connection made)
///   connect ─► fails → stop (connectFailed)
///   for each item, while budget and cancel allow:
///     originalFile ─► UploadEngine.upload(remote path = item.relativePath)
///       uploaded / already backed up ─► record version id
///       connection lost ─► stop (connectionLost)
///       other failure ─► record error on the item, go on
///   close
///
///  verifyAll: same loop over items already backed up and unchanged:
///   re-hash + FileOffer ─► existing version (fine)
///                      └─► NeedChunks(missing/bad) → sent → new version (repaired)
/// ```
///
/// Order is newest first: the newest photos exist only on the phone, and
/// M4 "a new photo appears on the server" must not wait days behind a
/// first backup of 20 000 old photos. A stopped run loses nothing: the
/// server keeps the chunks it confirmed and the next run's offer asks
/// only for the rest. Author: Hao Tran.
library;

import 'dart:io';

import '../client/nas_connection.dart';
import '../client/upload_engine.dart';
import 'backup_state_store.dart';
import 'media_source.dart';

/// Opens a ready connection to the paired server, or throws (any
/// [Exception]; its text becomes the report's problem).
typedef NasConnector = Future<NasConnection> Function();

/// Thrown by a [NasConnector] when no address worked.
class BackupConnectFailed implements Exception {
  const BackupConnectFailed(this.message, {this.isMaybeNotPaired = false});

  final String message;

  /// The server refused this phone (removed on the NAS).
  final bool isMaybeNotPaired;

  @override
  String toString() => message;
}

/// Background jobs get about 10 minutes from Android; stop before that.
const defaultRunBudget = Duration(minutes: 9);

enum BackupStopReason {
  /// Every picked item was handled (some may have failed).
  finished,

  /// The time budget ran out; the next run goes on.
  budgetUsed,

  /// [UploadCancel.cancel] was called.
  cancelled,

  /// The user gave no photo access.
  noMediaAccess,

  /// No address of the server worked.
  connectFailed,

  /// The connection ended in the middle of the run.
  connectionLost,
}

/// One item that failed, for the log and the report.
typedef BackupItemFailure = ({String remotePath, String message});

/// Where a run or verify is.
final class BackupProgress {
  const BackupProgress({
    required this.itemsDone,
    required this.itemsTotal,
    required this.currentPath,
    this.upload,
  });

  final int itemsDone;
  final int itemsTotal;
  final String currentPath;

  /// Chunk progress of the current file, when chunks are being sent.
  final UploadProgress? upload;
}

typedef BackupProgressCallback = void Function(BackupProgress progress);

final class BackupRunReport {
  const BackupRunReport({
    required this.startedAt,
    required this.finishedAt,
    required this.stopReason,
    required this.itemsScanned,
    required this.itemsPicked,
    required this.filesUploaded,
    required this.filesAlreadyBackedUp,
    required this.bytesUploaded,
    required this.failures,
    this.mediaAccess,
    this.problem,
  });

  final DateTime startedAt;
  final DateTime finishedAt;
  final BackupStopReason stopReason;
  final MediaAccess? mediaAccess;

  /// Photos and videos found on the phone.
  final int itemsScanned;

  /// New or changed ones this run tried to back up.
  final int itemsPicked;
  final int filesUploaded;

  /// Offered, but the server had the same content already.
  final int filesAlreadyBackedUp;
  final int bytesUploaded;
  final List<BackupItemFailure> failures;

  /// Why the run stopped early, for the user; null when it finished.
  final String? problem;

  int get filesFailed => failures.length;

  /// Picked items this run did not reach (budget, cancel, lost link).
  int get itemsLeft =>
      itemsPicked - filesUploaded - filesAlreadyBackedUp - filesFailed;

  @override
  String toString() =>
      'BackupRunReport(${stopReason.name}: $itemsScanned scanned, '
      '$itemsPicked picked, $filesUploaded uploaded, '
      '$filesAlreadyBackedUp already there, $filesFailed failed, '
      '$itemsLeft left${problem == null ? '' : ', $problem'})';
}

final class VerifyReport {
  const VerifyReport({
    required this.startedAt,
    required this.finishedAt,
    required this.stopReason,
    required this.filesChecked,
    required this.filesRepaired,
    required this.filesNotOnPhone,
    required this.filesChangedOnPhone,
    required this.failures,
    this.problem,
  });

  final DateTime startedAt;
  final DateTime finishedAt;
  final BackupStopReason stopReason;

  /// Offered again and answered by the server (fine or repaired).
  final int filesChecked;

  /// The server lacked chunks (missing or marked bad by scrub); they were
  /// sent again and a new complete version was made.
  final int filesRepaired;

  /// Backed up once, but deleted from the phone: cannot be checked.
  final int filesNotOnPhone;

  /// Changed since the backup: the next backup run uploads them.
  final int filesChangedOnPhone;
  final List<BackupItemFailure> failures;
  final String? problem;

  int get filesFailed => failures.length;

  @override
  String toString() =>
      'VerifyReport(${stopReason.name}: $filesChecked checked, '
      '$filesRepaired repaired, $filesFailed failed, '
      '$filesNotOnPhone not on phone, $filesChangedOnPhone changed'
      '${problem == null ? '' : ', $problem'})';
}

class BackupRunner {
  BackupRunner({
    required this.mediaSource,
    required this.stateStore,
    required this.connect,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final MediaSource mediaSource;
  final BackupStateStore stateStore;
  final NasConnector connect;

  /// Wall clock; the budget is measured with it.
  final DateTime Function() clock;

  /// True when [item] must be offered: never backed up, or not the copy
  /// the server has (moved, resized, re-saved).
  static bool needsUpload(MediaItem item, BackupRecord? record) =>
      record == null || !record.isBackedUp || !record.matches(item);

  Future<BackupRunReport> runOnce({
    Duration budget = defaultRunBudget,
    UploadCancel? cancel,
    BackupProgressCallback? onProgress,
  }) async {
    final startedAt = clock();
    final access = await mediaSource.requestAccess();
    if (!access.canRead) {
      return _runReport(
        startedAt,
        BackupStopReason.noMediaAccess,
        mediaAccess: access,
        problem: access.description,
      );
    }

    final items = await mediaSource.listItems().toList();
    final records = await stateStore.loadAll();
    final picked = [
      for (final item in items)
        if (needsUpload(item, records[item.id])) item,
    ]..sort(_newestFirst);
    if (picked.isEmpty) {
      return _runReport(
        startedAt,
        BackupStopReason.finished,
        mediaAccess: access,
        itemsScanned: items.length,
      );
    }

    final loop = _ItemLoop(
      runner: this,
      deadline: startedAt.add(budget),
      cancel: cancel,
      onProgress: onProgress,
      itemsTotal: picked.length,
      knownRecords: records,
    );
    final stop = await loop.run(picked, (engine, item, file, itemCancel) async {
      final result = await engine.upload(
        localPath: file.path,
        remotePath: item.relativePath,
        modifiedTimeMs: item.modifiedTimeMs,
        cancel: itemCancel,
        onProgress: loop.progressFor(item),
      );
      final nowMs = clock().millisecondsSinceEpoch;
      switch (result) {
        case UploadUploaded(:final versionId, :final bytesSent):
          await stateStore.put(_backedUpRecord(item, versionId, nowMs));
          loop.filesUploaded++;
          loop.bytesUploaded += bytesSent;
        case UploadAlreadyBackedUp(:final versionId):
          await stateStore.put(_backedUpRecord(item, versionId, nowMs));
          loop.filesAlreadyBackedUp++;
        case UploadFailed() || UploadCancelled():
          break;
      }
      return result;
    });
    return _runReport(
      startedAt,
      stop.reason,
      mediaAccess: access,
      problem: stop.problem,
      itemsScanned: items.length,
      itemsPicked: picked.length,
      filesUploaded: loop.filesUploaded,
      filesAlreadyBackedUp: loop.filesAlreadyBackedUp,
      bytesUploaded: loop.bytesUploaded,
      failures: loop.failures,
    );
  }

  /// Offers every backed-up, unchanged item again (M6 "verify backup",
  /// spec §8 repair note). The server answers "already backed up" for a
  /// complete copy, or asks for the chunks it lacks or marked bad; those
  /// are sent and a new complete version is made. Oldest-checked first,
  /// so a stopped verify goes on where it left off next time.
  Future<VerifyReport> verifyAll({
    Duration? budget,
    UploadCancel? cancel,
    BackupProgressCallback? onProgress,
  }) async {
    final startedAt = clock();
    final access = await mediaSource.requestAccess();
    if (!access.canRead) {
      return _verifyReport(
        startedAt,
        BackupStopReason.noMediaAccess,
        problem: access.description,
      );
    }
    final itemsById = {
      await for (final item in mediaSource.listItems()) item.id: item,
    };
    final backedUp =
        (await stateStore.loadAll()).values
            .where((record) => record.isBackedUp)
            .toList()
          ..sort(
            (first, second) => (first.lastVerifiedAtMs ?? 0).compareTo(
              second.lastVerifiedAtMs ?? 0,
            ),
          );
    var filesNotOnPhone = 0;
    var filesChangedOnPhone = 0;
    final toCheck = <(MediaItem, BackupRecord)>[];
    for (final record in backedUp) {
      final item = itemsById[record.mediaId];
      if (item == null) {
        filesNotOnPhone++;
      } else if (!record.matches(item)) {
        filesChangedOnPhone++;
      } else {
        toCheck.add((item, record));
      }
    }
    final recordsById = {for (final (item, record) in toCheck) item.id: record};

    var filesChecked = 0;
    var filesRepaired = 0;
    final loop = _ItemLoop(
      runner: this,
      deadline: budget == null ? null : startedAt.add(budget),
      cancel: cancel,
      onProgress: onProgress,
      itemsTotal: toCheck.length,
      knownRecords: recordsById,
    );
    final stop = await loop.run([for (final (item, _) in toCheck) item], (
      engine,
      item,
      file,
      itemCancel,
    ) async {
      final result = await engine.upload(
        localPath: file.path,
        remotePath: item.relativePath,
        modifiedTimeMs: item.modifiedTimeMs,
        cancel: itemCancel,
        onProgress: loop.progressFor(item),
      );
      final record = recordsById[item.id]!;
      final nowMs = clock().millisecondsSinceEpoch;
      switch (result) {
        case UploadAlreadyBackedUp(:final versionId):
          filesChecked++;
          await stateStore.put(
            record.copyWith(
              versionId: versionId,
              lastVerifiedAtMs: nowMs,
              clearError: true,
            ),
          );
        case UploadUploaded(:final versionId):
          filesChecked++;
          filesRepaired++;
          await stateStore.put(
            record.copyWith(
              versionId: versionId,
              backedUpAtMs: nowMs,
              lastVerifiedAtMs: nowMs,
              clearError: true,
            ),
          );
        case UploadFailed() || UploadCancelled():
          break;
      }
      return result;
    });
    return _verifyReport(
      startedAt,
      stop.reason,
      problem: stop.problem,
      filesChecked: filesChecked,
      filesRepaired: filesRepaired,
      filesNotOnPhone: filesNotOnPhone,
      filesChangedOnPhone: filesChangedOnPhone,
      failures: loop.failures,
    );
  }

  static int _newestFirst(MediaItem first, MediaItem second) {
    final byTime = second.modifiedTimeMs.compareTo(first.modifiedTimeMs);
    return byTime != 0 ? byTime : first.id.compareTo(second.id);
  }

  static BackupRecord _backedUpRecord(
    MediaItem item,
    int versionId,
    int nowMs,
  ) => BackupRecord(
    mediaId: item.id,
    remotePath: item.relativePath,
    sizeBytes: item.sizeBytes,
    modifiedTimeMs: item.modifiedTimeMs,
    versionId: versionId,
    backedUpAtMs: nowMs,
    lastVerifiedAtMs: nowMs,
  );

  BackupRunReport _runReport(
    DateTime startedAt,
    BackupStopReason stopReason, {
    MediaAccess? mediaAccess,
    String? problem,
    int itemsScanned = 0,
    int itemsPicked = 0,
    int filesUploaded = 0,
    int filesAlreadyBackedUp = 0,
    int bytesUploaded = 0,
    List<BackupItemFailure> failures = const [],
  }) => BackupRunReport(
    startedAt: startedAt,
    finishedAt: clock(),
    stopReason: stopReason,
    mediaAccess: mediaAccess,
    problem: problem,
    itemsScanned: itemsScanned,
    itemsPicked: itemsPicked,
    filesUploaded: filesUploaded,
    filesAlreadyBackedUp: filesAlreadyBackedUp,
    bytesUploaded: bytesUploaded,
    failures: failures,
  );

  VerifyReport _verifyReport(
    DateTime startedAt,
    BackupStopReason stopReason, {
    String? problem,
    int filesChecked = 0,
    int filesRepaired = 0,
    int filesNotOnPhone = 0,
    int filesChangedOnPhone = 0,
    List<BackupItemFailure> failures = const [],
  }) => VerifyReport(
    startedAt: startedAt,
    finishedAt: clock(),
    stopReason: stopReason,
    problem: problem,
    filesChecked: filesChecked,
    filesRepaired: filesRepaired,
    filesNotOnPhone: filesNotOnPhone,
    filesChangedOnPhone: filesChangedOnPhone,
    failures: failures,
  );
}

/// Uploads one item; returns the engine's result.
typedef _ItemAction = Future<UploadResult> Function(
  UploadEngine engine,
  MediaItem item,
  File file,
  UploadCancel itemCancel,
);

/// The loop both [BackupRunner.runOnce] and [BackupRunner.verifyAll]
/// share: connect, budget and cancel checks, per-item errors, close.
final class _ItemLoop {
  _ItemLoop({
    required this.runner,
    required this.deadline,
    required this.cancel,
    required this.onProgress,
    required this.itemsTotal,
    required this.knownRecords,
  });

  final BackupRunner runner;

  /// The records loaded at the start, by media id.
  final Map<String, BackupRecord> knownRecords;

  /// Null = no time limit.
  final DateTime? deadline;
  final UploadCancel? cancel;
  final BackupProgressCallback? onProgress;
  final int itemsTotal;

  int itemsDone = 0;
  int filesUploaded = 0;
  int filesAlreadyBackedUp = 0;
  int bytesUploaded = 0;
  final failures = <BackupItemFailure>[];

  /// Set when the budget or [cancel] stops the current file mid-way.
  UploadCancel _itemCancel = UploadCancel();

  bool get _isPastDeadline {
    final limit = deadline;
    return limit != null && !runner.clock().isBefore(limit);
  }

  bool get _isCancelled => cancel?.isCancelled ?? false;

  /// The upload's chunk callback: reports progress and stops the file
  /// between chunks when the budget is used or [cancel] was called.
  void Function(UploadProgress) progressFor(MediaItem item) => (upload) {
    if (_isPastDeadline || _isCancelled) _itemCancel.cancel();
    onProgress?.call(
      BackupProgress(
        itemsDone: itemsDone,
        itemsTotal: itemsTotal,
        currentPath: item.relativePath,
        upload: upload,
      ),
    );
  };

  ({BackupStopReason reason, String? problem}) _stopNow() => _isCancelled
      ? (reason: BackupStopReason.cancelled, problem: 'Stopped.')
      : (
          reason: BackupStopReason.budgetUsed,
          problem: 'Time is up for this run; the next run goes on.',
        );

  Future<({BackupStopReason reason, String? problem})> run(
    List<MediaItem> items,
    _ItemAction action,
  ) async {
    if (_isCancelled || _isPastDeadline) return _stopNow();
    final NasConnection connection;
    try {
      connection = await runner.connect();
    } on Exception catch (error) {
      return (
        reason: BackupStopReason.connectFailed,
        problem: 'Server not reachable: $error',
      );
    }
    final engine = UploadEngine(connection);
    try {
      for (final item in items) {
        if (_isCancelled || _isPastDeadline) return _stopNow();
        onProgress?.call(
          BackupProgress(
            itemsDone: itemsDone,
            itemsTotal: itemsTotal,
            currentPath: item.relativePath,
          ),
        );
        _itemCancel = UploadCancel();
        final result = await _handleItem(engine, item, action);
        switch (result) {
          case UploadCancelled():
            return _stopNow();
          case UploadFailed(
            kind: UploadFailureKind.connectionLost,
            :final message,
          ):
            return (
              reason: BackupStopReason.connectionLost,
              problem: 'Connection lost: $message',
            );
          case UploadFailed(:final message):
            failures.add((remotePath: item.relativePath, message: message));
            await _recordError(item, message);
          case UploadUploaded() || UploadAlreadyBackedUp():
            break;
        }
        itemsDone++;
      }
      return (reason: BackupStopReason.finished, problem: null);
    } finally {
      await connection.close();
    }
  }

  Future<UploadResult> _handleItem(
    UploadEngine engine,
    MediaItem item,
    _ItemAction action,
  ) async {
    final File? file;
    try {
      file = await runner.mediaSource.originalFile(item);
    } on Exception catch (error) {
      return UploadFailed(
        UploadFailureKind.fileUnreadable,
        'cannot open the original: $error',
      );
    }
    if (file == null) {
      return const UploadFailed(
        UploadFailureKind.fileUnreadable,
        'the original file is not on the phone',
      );
    }
    try {
      return await action(engine, item, file, _itemCancel);
    } finally {
      await runner.mediaSource.releaseOriginalFile(item);
    }
  }

  /// Keeps the record of what the server has; only notes the error. An
  /// item never backed up gets a record without a version id, so it is
  /// picked again next run.
  Future<void> _recordError(MediaItem item, String message) async {
    final record =
        knownRecords[item.id] ??
        BackupRecord(
          mediaId: item.id,
          remotePath: item.relativePath,
          sizeBytes: item.sizeBytes,
          modifiedTimeMs: item.modifiedTimeMs,
        );
    await runner.stateStore.put(record.copyWith(lastError: message));
  }
}
