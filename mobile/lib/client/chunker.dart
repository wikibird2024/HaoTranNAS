/// Cuts a file into `chunkSizeBytes` chunks and SHA-256 hashes each one
/// (spec §8 "Chunking"), streaming so a big video never sits in memory.
///
/// ```
///  file ─► read 1 MiB ─┬─► SHA-256(chunk)  ─► chunkHashes[i]
///                      └─► SHA-256(stream) ─► fileSha256   (same pass)
/// ```
///
/// The work runs in another isolate (`Isolate.run`) so hashing a video
/// does not freeze the UI. Author: Hao Tran.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/limits.dart';

/// What [chunkFile] found: the numbers that go into a FileOffer.
final class ChunkList {
  const ChunkList({
    required this.sizeBytes,
    required this.chunkHashes,
    required this.fileSha256,
  });

  final int sizeBytes;

  /// SHA-256 of each chunk, in file order; empty for a 0-byte file.
  final List<Uint8List> chunkHashes;

  /// SHA-256 of the whole file (of empty input for a 0-byte file).
  final Uint8List fileSha256;

  int get chunkCount => chunkHashes.length;
}

/// `ceil(sizeBytes / chunkSizeBytes)`; 0 for a 0-byte file.
int expectedChunkCount(int sizeBytes) =>
    (sizeBytes + chunkSizeBytes - 1) ~/ chunkSizeBytes;

/// Size of chunk [chunkIndex] of a [sizeBytes] file: 1 MiB, except the
/// last chunk, which holds the rest. Throws [RangeError] for an index
/// outside the file.
int expectedChunkSizeBytes(int sizeBytes, int chunkIndex) {
  RangeError.checkValidIndex(
    chunkIndex,
    null,
    'chunkIndex',
    expectedChunkCount(sizeBytes),
  );
  final restBytes = sizeBytes - chunkIndex * chunkSizeBytes;
  return restBytes < chunkSizeBytes ? restBytes : chunkSizeBytes;
}

/// Hashes the file at [path] chunk by chunk, in another isolate. The size
/// is what was read up to the end of the file, so the result always
/// describes one consistent pass. Throws [FileSystemException] when the
/// file cannot be read.
Future<ChunkList> chunkFile(String path) =>
    Isolate.run(() => chunkFileSync(path));

/// [chunkFile] on the calling isolate: for code already off the UI
/// isolate, and tests.
ChunkList chunkFileSync(String path) {
  final file = File(path).openSync();
  try {
    final buffer = Uint8List(chunkSizeBytes);
    final chunkHashes = <Uint8List>[];
    final fileDigest = _DigestSink();
    final fileHasher = sha256.startChunkedConversion(fileDigest);
    var sizeBytes = 0;
    while (true) {
      final readBytes = _readFull(file, buffer);
      if (readBytes == 0) break;
      final chunk = Uint8List.sublistView(buffer, 0, readBytes);
      chunkHashes.add(Uint8List.fromList(sha256.convert(chunk).bytes));
      fileHasher.add(chunk);
      sizeBytes += readBytes;
      if (readBytes < buffer.length) break;
    }
    fileHasher.close();
    return ChunkList(
      sizeBytes: sizeBytes,
      chunkHashes: chunkHashes,
      fileSha256: fileDigest.bytes,
    );
  } finally {
    file.closeSync();
  }
}

/// Reads chunk [chunkIndex] of a file that was [sizeBytes] long when it
/// was hashed, in another isolate. Returns fewer bytes than expected when
/// the file got shorter since: the caller's hash check then fails.
/// Throws [RangeError] for an index outside the file and
/// [FileSystemException] when the file cannot be read.
Future<Uint8List> readChunk(String path, int chunkIndex, int sizeBytes) =>
    Isolate.run(() => readChunkSync(path, chunkIndex, sizeBytes));

/// [readChunk] on the calling isolate.
Uint8List readChunkSync(String path, int chunkIndex, int sizeBytes) {
  final chunkBytes = expectedChunkSizeBytes(sizeBytes, chunkIndex);
  final file = File(path).openSync();
  try {
    file.setPositionSync(chunkIndex * chunkSizeBytes);
    final buffer = Uint8List(chunkBytes);
    final readBytes = _readFull(file, buffer);
    return readBytes == chunkBytes
        ? buffer
        : Uint8List.sublistView(buffer, 0, readBytes);
  } finally {
    file.closeSync();
  }
}

/// Fills [buffer] unless the file ends first; returns the bytes read.
int _readFull(RandomAccessFile file, Uint8List buffer) {
  var filledBytes = 0;
  while (filledBytes < buffer.length) {
    final readBytes = file.readIntoSync(buffer, filledBytes);
    if (readBytes == 0) break;
    filledBytes += readBytes;
  }
  return filledBytes;
}

/// Keeps the one digest a chunked SHA-256 conversion produces.
final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Uint8List get bytes => Uint8List.fromList(_digest!.bytes);

  @override
  void add(Digest digest) => _digest = digest;

  @override
  void close() {}
}
