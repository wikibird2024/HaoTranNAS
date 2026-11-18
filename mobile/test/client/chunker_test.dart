import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/client/chunker.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';

import '../protocol/vector_files.dart';

/// The vector generator's file: byte[i] = i mod 251.
Uint8List generatorBytes(int sizeBytes) => Uint8List.fromList([
  for (var index = 0; index < sizeBytes; index++) index % 251,
]);

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync('chunker_test');
  });

  tearDown(() => temporaryDirectory.deleteSync(recursive: true));

  String writeFile(String name, List<int> bytes) {
    final file = File('${temporaryDirectory.path}/$name')
      ..writeAsBytesSync(bytes);
    return file.path;
  }

  group('protocol/vectors/chunking.json', () {
    final vectors = loadVectorFile('chunking.json');
    test('chunk size matches limits', () {
      expect(vectors['chunk_size_bytes'], chunkSizeBytes);
    });

    for (final vector
        in (vectors['files'] as List).cast<Map<String, dynamic>>()) {
      final sizeBytes = int.parse(vector['size_bytes'] as String);
      final expectedHashes = [
        for (final hash in vector['chunk_hashes'] as List) hash as String,
      ];
      final expectedFileSha256 = vector['file_sha256'] as String;

      test('$sizeBytes bytes: chunk hashes and file SHA-256', () async {
        final path = writeFile(
          'vector_$sizeBytes.bin',
          generatorBytes(sizeBytes),
        );

        final chunkList = await chunkFile(path);

        expect(chunkList.sizeBytes, sizeBytes);
        expect(chunkList.chunkCount, expectedChunkCount(sizeBytes));
        expect([
          for (final hash in chunkList.chunkHashes) toHex(hash, separator: ''),
        ], expectedHashes);
        expect(toHex(chunkList.fileSha256, separator: ''), expectedFileSha256);
      });

      test('$sizeBytes bytes: readChunk returns each chunk exactly', () async {
        final path = writeFile(
          'vector_$sizeBytes.bin',
          generatorBytes(sizeBytes),
        );
        for (
          var chunkIndex = 0;
          chunkIndex < expectedHashes.length;
          chunkIndex++
        ) {
          final chunk = await readChunk(path, chunkIndex, sizeBytes);
          expect(chunk.length, expectedChunkSizeBytes(sizeBytes, chunkIndex));
          expect(
            sha256.convert(chunk).toString(),
            expectedHashes[chunkIndex],
            reason: 'chunk $chunkIndex',
          );
        }
      });
    }
  });

  group('size helpers', () {
    test('expectedChunkCount', () {
      expect(expectedChunkCount(0), 0);
      expect(expectedChunkCount(1), 1);
      expect(expectedChunkCount(chunkSizeBytes), 1);
      expect(expectedChunkCount(chunkSizeBytes + 1), 2);
      expect(
        expectedChunkCount(maxChunksPerFile * chunkSizeBytes),
        maxChunksPerFile,
      );
    });

    test('expectedChunkSizeBytes: full chunks, last holds the rest', () {
      const sizeBytes = 3 * chunkSizeBytes + 17;
      expect(expectedChunkSizeBytes(sizeBytes, 0), chunkSizeBytes);
      expect(expectedChunkSizeBytes(sizeBytes, 2), chunkSizeBytes);
      expect(expectedChunkSizeBytes(sizeBytes, 3), 17);
      expect(expectedChunkSizeBytes(chunkSizeBytes, 0), chunkSizeBytes);
    });

    test('expectedChunkSizeBytes: index outside the file → RangeError', () {
      expect(() => expectedChunkSizeBytes(17, 1), throwsRangeError);
      expect(() => expectedChunkSizeBytes(0, 0), throwsRangeError);
      expect(() => expectedChunkSizeBytes(17, -1), throwsRangeError);
    });
  });

  group('errors', () {
    test('missing file → FileSystemException through the isolate', () async {
      await expectLater(
        chunkFile('${temporaryDirectory.path}/missing.bin'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'readChunk of a file that got shorter returns the short rest',
      () async {
        final path = writeFile('short.bin', generatorBytes(100));
        final chunk = await readChunk(path, 1, chunkSizeBytes + 500);
        expect(chunk, isEmpty);
      },
    );

    test('readChunk index outside the file → RangeError', () async {
      final path = writeFile('small.bin', generatorBytes(100));
      await expectLater(readChunk(path, 1, 100), throwsRangeError);
    });
  });
}
