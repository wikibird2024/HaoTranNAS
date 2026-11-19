/// Uploads one file (spec §8): FileOffer → NeedChunks → ChunkData for
/// each missing chunk → Commit. Resume comes from re-sending the same
/// offer; the server answers with only what it still needs.
///
/// ```
///  path check ─► chunkFile ─► FileOffer ─► NeedChunks
///                                 ▲          │ existing version → alreadyBackedUp
///                                 │          ▼
///                                 │   for each missing index:
///                                 │     read + re-hash (≠ offer → fileChanged)
///                                 │     ChunkData ─► ChunkOk (same index + hash)
///                                 │          ▼
///                                 └─ CHUNKS_MISSING ◄─ Commit ─► CommitOk → uploaded
///                                    (max 3 offers)
/// ```
///
/// Never commits a file whose bytes changed after hashing. A cancel or a
/// failure leaves the upload uncommitted on the server; the next
/// [UploadEngine.upload] of the same file re-offers and sends only the
/// chunks the server still lacks. Author: Hao Tran.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import '../protocol/error_codes.dart';
import '../protocol/limits.dart';
import '../protocol/messages.dart';
import '../protocol/path_rules.dart';
import 'chunker.dart';
import 'nas_connection.dart';

/// Most FileOffers for one upload: the first one plus two re-offers after
/// `CHUNKS_MISSING`.
const int maxOfferRounds = 3;

/// Largest file one upload can carry (64 GiB).
const int maxUploadSizeBytes = maxChunksPerFile * chunkSizeBytes;

/// Set [cancel] from anywhere; the upload stops before its next chunk
/// and does not commit.
final class UploadCancel {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

/// Where an upload is, sent after each chunk the server confirmed.
final class UploadProgress {
  const UploadProgress({
    required this.chunksSent,
    required this.chunksToSend,
    required this.bytesSent,
    required this.totalChunks,
    required this.sizeBytes,
  });

  /// Chunks confirmed by ChunkOk so far in this call.
  final int chunksSent;

  /// [chunksSent] plus what the current NeedChunks still asks for.
  final int chunksToSend;

  /// Chunk data bytes confirmed so far in this call.
  final int bytesSent;

  /// Chunks in the whole file; chunks the server already has are not sent.
  final int totalChunks;
  final int sizeBytes;

  @override
  String toString() =>
      'UploadProgress($chunksSent/$chunksToSend chunks, $bytesSent bytes)';
}

/// Why an upload stopped without a committed version.
enum UploadFailureKind {
  /// The remote path breaks the path rules (checked here, or BAD_PATH).
  badPath,

  /// More than `maxChunksPerFile` chunks (checked here, or TOO_LARGE).
  tooLarge,

  /// The server has no space (DISK_FULL).
  diskFull,

  /// A chunk read for sending no longer matches the hash in the offer.
  /// Nothing was committed; hash the file again later.
  fileChangedDuringUpload,

  /// The local file could not be opened or read.
  fileUnreadable,

  /// Commit said CHUNKS_MISSING after [maxOfferRounds] offers.
  chunksStillMissing,

  /// The server answered with something the protocol does not allow
  /// (wrong ChunkOk, index out of range, upload id 0).
  badReply,

  /// Any other Error from the server; see [UploadFailed.errorCode].
  serverRejected,

  /// The connection ended; see [UploadFailed.connectionFailure].
  connectionLost,
}

/// How one [UploadEngine.upload] call ended. It never throws for a
/// network, server or file problem: those come back as [UploadFailed].
sealed class UploadResult {
  const UploadResult();

  const factory UploadResult.uploaded({
    required int versionId,
    required int chunksSent,
    required int bytesSent,
    required int totalChunks,
  }) = UploadUploaded;

  const factory UploadResult.alreadyBackedUp(int versionId) =
      UploadAlreadyBackedUp;

  bool get isBackedUp =>
      this is UploadUploaded || this is UploadAlreadyBackedUp;
}

/// Committed: the server made [versionId].
final class UploadUploaded extends UploadResult {
  const UploadUploaded({
    required this.versionId,
    required this.chunksSent,
    required this.bytesSent,
    required this.totalChunks,
  });

  final int versionId;

  /// Chunks this call sent; the others were already on the server.
  final int chunksSent;
  final int bytesSent;
  final int totalChunks;

  @override
  String toString() =>
      'uploaded: version $versionId, $chunksSent of $totalChunks chunks sent '
      '($bytesSent bytes)';
}

/// The same path, size, time and content is already version [versionId]
/// on the server. Nothing was sent or committed.
final class UploadAlreadyBackedUp extends UploadResult {
  const UploadAlreadyBackedUp(this.versionId);

  final int versionId;

  @override
  String toString() => 'already backed up as version $versionId';
}

/// [UploadCancel.cancel] was called; nothing was committed.
final class UploadCancelled extends UploadResult {
  const UploadCancelled({required this.chunksSent, required this.bytesSent});

  final int chunksSent;
  final int bytesSent;

  @override
  String toString() => 'cancelled after $chunksSent chunks';
}

/// Stopped on a problem; nothing was committed.
final class UploadFailed extends UploadResult {
  const UploadFailed(
    this.kind,
    this.message, {
    this.errorCode,
    this.connectionFailure,
  });

  final UploadFailureKind kind;

  /// One line for a person.
  final String message;

  /// The raw `Error.code` when the server refused a request.
  final int? errorCode;

  /// Why the connection ended, for [UploadFailureKind.connectionLost].
  final NasFailure? connectionFailure;

  @override
  String toString() => 'upload failed (${kind.name}): $message';
}

/// Uploads files over one [NasConnection], one at a time.
class UploadEngine {
  UploadEngine(this.connection);

  final NasConnection connection;

  /// Backs up [localPath] as [remotePath] (spec §10 path rules) with the
  /// phone's [modifiedTimeMs]. [onProgress] is called after each chunk
  /// the server confirms.
  Future<UploadResult> upload({
    required String localPath,
    required String remotePath,
    required int modifiedTimeMs,
    void Function(UploadProgress progress)? onProgress,
    UploadCancel? cancel,
  }) async {
    final pathProblemText = pathProblem(remotePath);
    if (pathProblemText != null) {
      return UploadFailed(
        UploadFailureKind.badPath,
        'remote path not allowed: $pathProblemText',
      );
    }

    final ChunkList chunkList;
    try {
      final fileSizeBytes = await File(localPath).length();
      if (fileSizeBytes > maxUploadSizeBytes) {
        return UploadFailed(
          UploadFailureKind.tooLarge,
          '$fileSizeBytes bytes, more than $maxUploadSizeBytes',
        );
      }
      chunkList = await chunkFile(localPath);
    } on FileSystemException catch (error) {
      return UploadFailed(
        UploadFailureKind.fileUnreadable,
        'cannot read $localPath: ${error.message}',
      );
    }
    if (chunkList.chunkCount > maxChunksPerFile) {
      return UploadFailed(
        UploadFailureKind.tooLarge,
        '${chunkList.chunkCount} chunks, more than $maxChunksPerFile',
      );
    }

    final upload = _Upload(
      connection: connection,
      localPath: localPath,
      offer: FileOffer(
        path: remotePath,
        sizeBytes: chunkList.sizeBytes,
        modifiedTimeMs: modifiedTimeMs,
        fileSha256: chunkList.fileSha256,
        chunkHashes: chunkList.chunkHashes,
      ),
      onProgress: onProgress,
      cancel: cancel,
    );
    try {
      return await upload.run();
    } on NasRequestError catch (error) {
      return _failureFor(error);
    } on NasFailure catch (failure) {
      return UploadFailed(
        UploadFailureKind.connectionLost,
        failure.message,
        connectionFailure: failure,
      );
    } on FileSystemException catch (error) {
      return UploadFailed(
        UploadFailureKind.fileUnreadable,
        'cannot read $localPath: ${error.message}',
      );
    }
  }

  static UploadFailed _failureFor(NasRequestError error) {
    final kind = switch (error.knownCode) {
      ErrorCode.badPath => UploadFailureKind.badPath,
      ErrorCode.tooLarge => UploadFailureKind.tooLarge,
      ErrorCode.diskFull => UploadFailureKind.diskFull,
      ErrorCode.chunksMissing => UploadFailureKind.chunksStillMissing,
      _ => UploadFailureKind.serverRejected,
    };
    return UploadFailed(
      kind,
      'server error ${error.codeName}: ${error.message}',
      errorCode: error.code,
    );
  }
}

/// The state of one upload call.
final class _Upload {
  _Upload({
    required this.connection,
    required this.localPath,
    required this.offer,
    required this.onProgress,
    required this.cancel,
  });

  final NasConnection connection;
  final String localPath;
  final FileOffer offer;
  final void Function(UploadProgress progress)? onProgress;
  final UploadCancel? cancel;

  int chunksSent = 0;
  int bytesSent = 0;

  int get totalChunks => offer.chunkHashes.length;

  bool get isCancelled => cancel?.isCancelled ?? false;

  UploadCancelled get cancelled =>
      UploadCancelled(chunksSent: chunksSent, bytesSent: bytesSent);

  /// Throws [NasRequestError] / [NasFailure] / [FileSystemException];
  /// the caller turns them into [UploadFailed].
  Future<UploadResult> run() async {
    NasRequestError? lastChunksMissing;
    for (var round = 1; round <= maxOfferRounds; round++) {
      if (isCancelled) return cancelled;
      final needChunks = await connection.request(offer) as NeedChunks;
      if (needChunks.existingVersionId != 0) {
        return UploadResult.alreadyBackedUp(needChunks.existingVersionId);
      }
      final replyProblem = _needChunksProblem(needChunks);
      if (replyProblem != null) {
        return UploadFailed(UploadFailureKind.badReply, replyProblem);
      }

      final chunksToSend = chunksSent + needChunks.missingIndexes.length;
      for (final chunkIndex in needChunks.missingIndexes) {
        if (isCancelled) return cancelled;
        final failure = await _sendChunk(
          needChunks.uploadId,
          chunkIndex,
          chunksToSend,
        );
        if (failure != null) return failure;
      }

      if (isCancelled) return cancelled;
      try {
        final commitOk = await connection.request(
          Commit(uploadId: needChunks.uploadId),
          // The server re-reads the whole file before CommitOk (D-030).
          timeout: Duration(milliseconds: commitTimeoutMs(offer.sizeBytes)),
        ) as CommitOk;
        return UploadResult.uploaded(
          versionId: commitOk.versionId,
          chunksSent: chunksSent,
          bytesSent: bytesSent,
          totalChunks: totalChunks,
        );
      } on NasRequestError catch (error) {
        // A chunk was marked bad after the offer: offer again (spec §8),
        // never Commit alone.
        if (error.knownCode != ErrorCode.chunksMissing) rethrow;
        lastChunksMissing = error;
      }
    }
    return UploadFailed(
      UploadFailureKind.chunksStillMissing,
      'Commit said CHUNKS_MISSING after $maxOfferRounds offers: '
      '${lastChunksMissing?.message}',
      errorCode: ErrorCode.chunksMissing.number,
    );
  }

  String? _needChunksProblem(NeedChunks needChunks) {
    if (needChunks.uploadId == 0) {
      return 'NeedChunks with upload id 0 and no existing version';
    }
    var previousIndex = -1;
    for (final chunkIndex in needChunks.missingIndexes) {
      if (chunkIndex >= totalChunks) {
        return 'NeedChunks asks for chunk $chunkIndex of $totalChunks';
      }
      if (chunkIndex <= previousIndex) {
        return 'NeedChunks indexes not ascending at $chunkIndex';
      }
      previousIndex = chunkIndex;
    }
    return null;
  }

  /// Reads, re-checks and sends one chunk; null when the server confirmed
  /// it.
  Future<UploadFailed?> _sendChunk(
    int uploadId,
    int chunkIndex,
    int chunksToSend,
  ) async {
    final offeredHash = offer.chunkHashes[chunkIndex];
    final chunk = await _readAndHashChunk(
      localPath,
      chunkIndex,
      offer.sizeBytes,
    );
    if (!_sameBytes(chunk.sha256, offeredHash)) {
      return UploadFailed(
        UploadFailureKind.fileChangedDuringUpload,
        'chunk $chunkIndex of $localPath changed after it was hashed',
      );
    }
    final chunkOk = await connection.request(
      ChunkData(
        uploadId: uploadId,
        chunkIndex: chunkIndex,
        chunkSha256: offeredHash,
        data: chunk.data,
      ),
    ) as ChunkOk;
    if (chunkOk.chunkIndex != chunkIndex ||
        !_sameBytes(chunkOk.chunkSha256, offeredHash)) {
      return UploadFailed(
        UploadFailureKind.badReply,
        'ChunkOk(${chunkOk.chunkIndex}) does not confirm chunk $chunkIndex',
      );
    }
    chunksSent++;
    bytesSent += chunk.data.length;
    onProgress?.call(
      UploadProgress(
        chunksSent: chunksSent,
        chunksToSend: chunksToSend,
        bytesSent: bytesSent,
        totalChunks: totalChunks,
        sizeBytes: offer.sizeBytes,
      ),
    );
    return null;
  }
}

/// Reads and hashes one chunk in another isolate, so the UI isolate never
/// hashes 1 MiB.
Future<({Uint8List data, Uint8List sha256})> _readAndHashChunk(
  String path,
  int chunkIndex,
  int sizeBytes,
) => Isolate.run(() {
  final data = readChunkSync(path, chunkIndex, sizeBytes);
  return (data: data, sha256: Uint8List.fromList(sha256.convert(data).bytes));
});

bool _sameBytes(Uint8List first, Uint8List second) =>
    const ListEquality<int>().equals(first, second);
