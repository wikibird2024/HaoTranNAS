// A scripted upload server on top of [FakeServer]: keeps a chunk store
// and versions in memory and follows the spec §8 rules (missing indexes,
// ChunkData checks, Commit checks), with hooks a test can use to bend
// them. Used by the UploadEngine tests.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:haotrannas_client/client/chunker.dart';
import 'package:haotrannas_client/core/bytes/hex.dart';
import 'package:haotrannas_client/protocol/error_codes.dart';
import 'package:haotrannas_client/protocol/messages.dart';

import 'fake_server.dart';

/// One committed version of a path.
typedef FakeVersion = ({int versionId, FileOffer offer, Uint8List content});

class FakeUploadServer {
  FakeUploadServer() {
    server.answer = _answer;
  }

  final server = FakeServer();

  /// Stored chunks by hex hash.
  final storedChunks = <String, Uint8List>{};

  /// Latest version of each path.
  final latestVersions = <String, FakeVersion>{};

  final _openUploads = <int, FileOffer>{};
  int _nextUploadId = 1000;
  int _nextVersionId = 1;

  /// Called with each request before it is answered (e.g. to change the
  /// local file under the phone's feet).
  void Function(Message request)? onRequest;

  /// A reply that replaces the normal one; null = normal rules.
  Message? Function(Message request)? replyOverride;

  /// Commits left that find chunk [badChunkIndex] "marked bad by scrub":
  /// the chunk is dropped from the store and Commit says CHUNKS_MISSING.
  int badChunkCommitsLeft = 0;
  int badChunkIndex = 0;

  List<Message> get sentMessages => server.sentMessages;

  List<T> sentOfType<T extends Message>() =>
      server.sentMessages.whereType<T>().toList();

  /// Puts [chunks] in the store as if another upload sent them.
  void storeChunks(Iterable<Uint8List> chunks) {
    for (final chunk in chunks) {
      storedChunks[_hexHash(chunk)] = chunk;
    }
  }

  Message? _answer(Message request) {
    onRequest?.call(request);
    final override = replyOverride?.call(request);
    if (override != null) return override;
    return switch (request) {
      FileOffer() => _onFileOffer(request),
      ChunkData() => _onChunkData(request),
      Commit() => _onCommit(request),
      _ => FakeServer.defaultAnswer(request),
    };
  }

  Message _onFileOffer(FileOffer offer) {
    final latest = latestVersions[offer.path];
    if (latest != null &&
        latest.offer.sizeBytes == offer.sizeBytes &&
        latest.offer.modifiedTimeMs == offer.modifiedTimeMs &&
        _hex(latest.offer.fileSha256) == _hex(offer.fileSha256)) {
      return NeedChunks(
        uploadId: 0,
        existingVersionId: latest.versionId,
        missingIndexes: const [],
      );
    }
    final uploadId = _nextUploadId++;
    _openUploads[uploadId] = offer;
    final seenHashes = <String>{};
    final missingIndexes = <int>[];
    for (var index = 0; index < offer.chunkHashes.length; index++) {
      final hash = _hex(offer.chunkHashes[index]);
      if (!seenHashes.add(hash)) continue;
      if (!storedChunks.containsKey(hash)) missingIndexes.add(index);
    }
    return NeedChunks(
      uploadId: uploadId,
      existingVersionId: 0,
      missingIndexes: missingIndexes,
    );
  }

  Message _onChunkData(ChunkData chunkData) {
    final offer = _openUploads[chunkData.uploadId];
    if (offer == null) return _error(ErrorCode.unknownUpload, 'no upload');
    final index = chunkData.chunkIndex;
    if (index >= offer.chunkHashes.length) {
      return _error(ErrorCode.badArgument, 'index $index');
    }
    final offeredHash = _hex(offer.chunkHashes[index]);
    if (_hex(chunkData.chunkSha256) != offeredHash) {
      return _error(ErrorCode.chunkHashMismatch, 'not the offered hash');
    }
    if (chunkData.data.length !=
        expectedChunkSizeBytes(offer.sizeBytes, index)) {
      return _error(ErrorCode.chunkSizeWrong, 'chunk $index size');
    }
    if (_hexHash(chunkData.data) != offeredHash) {
      return _error(ErrorCode.chunkHashMismatch, 'data does not match');
    }
    storedChunks[offeredHash] = Uint8List.fromList(chunkData.data);
    return ChunkOk(chunkIndex: index, chunkSha256: chunkData.chunkSha256);
  }

  Message _onCommit(Commit commit) {
    final offer = _openUploads[commit.uploadId];
    if (offer == null) return _error(ErrorCode.unknownUpload, 'no upload');
    if (badChunkCommitsLeft > 0) {
      badChunkCommitsLeft--;
      storedChunks.remove(_hex(offer.chunkHashes[badChunkIndex]));
    }
    final content = BytesBuilder(copy: false);
    for (final hash in offer.chunkHashes) {
      final chunk = storedChunks[_hex(hash)];
      if (chunk == null) {
        return _error(ErrorCode.chunksMissing, 'chunk ${_hex(hash)} missing');
      }
      content.add(chunk);
    }
    final contentBytes = content.toBytes();
    if (_hexHash(contentBytes) != _hex(offer.fileSha256)) {
      _openUploads.remove(commit.uploadId);
      return _error(ErrorCode.fileHashMismatch, 'file hash');
    }
    _openUploads.remove(commit.uploadId);
    final versionId = _nextVersionId++;
    latestVersions[offer.path] = (
      versionId: versionId,
      offer: offer,
      content: contentBytes,
    );
    return CommitOk(versionId: versionId);
  }

  static ErrorMessage _error(ErrorCode code, String text) =>
      ErrorMessage(code: code.number, message: text);

  static String _hex(Uint8List bytes) => toHex(bytes, separator: '');

  static String _hexHash(Uint8List bytes) => sha256.convert(bytes).toString();
}
