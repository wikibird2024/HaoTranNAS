// DownloadEngine on a fake server (fake_download_server.dart): listing
// with paging, full download, every check that must stop a download
// (chunk hash, chunk size, file hash), cancel, NOT_FOUND, connection
// lost, never overwriting, restore under a free name. Author: Hao Tran.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/testing/fake_download_server.dart';

/// [sizeBytes] bytes that differ per position, so a swapped chunk shows.
Uint8List patternBytes(int sizeBytes, {int seed = 1}) {
  final bytes = Uint8List(sizeBytes);
  for (var index = 0; index < sizeBytes; index++) {
    bytes[index] = (index * 31 + seed + index ~/ chunkSizeBytes) & 0xFF;
  }
  return bytes;
}

void main() {
  late Directory temporaryDirectory;
  late FakeDownloadServer fakeServer;
  late NasConnection connection;
  late DownloadEngine engine;

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync('download_test');
    fakeServer = FakeDownloadServer();
    connection = await NasConnection.open(
      fakeServer.server.link,
      clientSoftware: 'haotrannas-mobile test',
      deviceName: 'test phone',
    );
    engine = DownloadEngine(connection);
  });

  tearDown(() async {
    await connection.close();
    temporaryDirectory.deleteSync(recursive: true);
  });

  String outputPath(String name) => '${temporaryDirectory.path}/$name';

  /// Files in the temp folder, so a test sees a left-over `.part`.
  List<String> leftFiles() => [
    for (final entity in temporaryDirectory.listSync(recursive: true))
      if (entity is File) entity.path.substring(temporaryDirectory.path.length),
  ]..sort();

  group('browse', () {
    test('listDevices returns every device', () async {
      final devices = await engine.listDevices();
      expect(
        [for (final device in devices) device.name],
        ['test phone', 'laptop'],
      );
      expect(devices.first.isCaller, isTrue);
    });

    test('listDir pages over 3 pages with start_after', () async {
      for (var index = 0; index < 7; index++) {
        fakeServer.addFile('DCIM/photo-$index.jpg', Uint8List.fromList([1]));
      }
      fakeServer.addFile('DCIM/Camera/a.jpg', Uint8List.fromList([2]));
      final entries = await engine.listDirAll(
        deviceId: 0,
        path: 'DCIM',
        pageSize: 3,
      );
      expect(
        [for (final entry in entries) entry.name],
        [
          'Camera',
          'photo-0.jpg',
          'photo-1.jpg',
          'photo-2.jpg',
          'photo-3.jpg',
          'photo-4.jpg',
          'photo-5.jpg',
          'photo-6.jpg',
        ],
      );
      expect(entries.first.kind, DirEntryKind.directory);
      expect(fakeServer.listDirRequests, hasLength(3));
      expect(
        [for (final request in fakeServer.listDirRequests) request.startAfter],
        ['', 'photo-1.jpg', 'photo-4.jpg'],
      );
      expect(fakeServer.listDirRequests.first.maxEntries, 3);
    });

    test(
      'listDir asks for the next page only when the stream is read',
      () async {
        for (var index = 0; index < 5; index++) {
          fakeServer.addFile('f$index', Uint8List.fromList([1]));
        }
        final firstTwo = await engine
            .listDir(deviceId: 0, path: '', pageSize: 2)
            .take(2)
            .toList();
        expect(firstTwo, hasLength(2));
        expect(fakeServer.listDirRequests, hasLength(1));
      },
    );

    test('empty root is an empty list', () async {
      expect(await engine.listDirAll(deviceId: 0, path: ''), isEmpty);
    });

    test('NOT_FOUND folder → BrowseFailed(notFound)', () async {
      await expectLater(
        engine.listDirPage(deviceId: 0, path: 'nope'),
        throwsA(
          isA<BrowseFailed>().having(
            (failed) => failed.kind,
            'kind',
            BrowseFailureKind.notFound,
          ),
        ),
      );
    });

    test('bad path is refused before sending', () async {
      await expectLater(
        engine.listDirPage(deviceId: 0, path: '../etc'),
        throwsA(
          isA<BrowseFailed>().having(
            (failed) => failed.kind,
            'kind',
            BrowseFailureKind.badPath,
          ),
        ),
      );
      expect(fakeServer.listDirRequests, isEmpty);
    });

    test('a page that does not move forward → badReply', () async {
      fakeServer.server.answer = (request) => request is ListDir
          ? const DirEntries(entries: [], hasMore: true)
          : FakeDownloadServer.notFound('x');
      await expectLater(
        engine.listDirAll(deviceId: 0, path: ''),
        throwsA(
          isA<BrowseFailed>().having(
            (failed) => failed.kind,
            'kind',
            BrowseFailureKind.badReply,
          ),
        ),
      );
    });

    test('compareUtf8Bytes sorts by UTF-8 bytes, not UTF-16 units', () {
      // U+FF5E is one UTF-16 unit, U+1F600 two (high surrogate D83D);
      // in UTF-8, EF BD 9E < F0 9F 98 80.
      expect(compareUtf8Bytes('\u{FF5E}', '\u{1F600}'), lessThan(0));
      expect('\u{FF5E}'.compareTo('\u{1F600}'), greaterThan(0));
    });
  });

  group('download', () {
    test('3 MiB + 17 B: byte-equal, progress per chunk, no .part', () async {
      final content = patternBytes(3 * chunkSizeBytes + 17);
      fakeServer.addFile('DCIM/big.bin', content, versionId: 42);
      final progress = <DownloadProgress>[];
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'DCIM/big.bin',
        outputPath: outputPath('big.bin'),
        onProgress: progress.add,
      );
      expect(result, isA<DownloadDone>());
      final done = result as DownloadDone;
      expect(done.versionId, 42);
      expect(done.sizeBytes, content.length);
      expect(File(outputPath('big.bin')).readAsBytesSync(), content);
      expect(leftFiles(), ['/big.bin']);
      expect([for (final step in progress) step.chunksDone], [1, 2, 3, 4]);
      expect(progress.last.bytesDone, content.length);
      expect(progress.last.fraction, 1.0);
      final readChunks = fakeServer.server.sentMessages.whereType<ReadChunk>();
      expect(readChunks, hasLength(4));
    });

    test('empty file downloads as an empty file', () async {
      fakeServer.addFile('empty.txt', Uint8List(0));
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'empty.txt',
        outputPath: outputPath('empty.txt'),
      );
      expect(result, isA<DownloadDone>());
      expect(File(outputPath('empty.txt')).lengthSync(), 0);
    });

    test('wrong chunk bytes → chunkHashMismatch, nothing left', () async {
      fakeServer.addFile('a.bin', patternBytes(2 * chunkSizeBytes + 5));
      fakeServer.corruptChunkIndex = 1;
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'a.bin',
        outputPath: outputPath('a.bin'),
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.chunkHashMismatch,
        ),
      );
      expect(leftFiles(), isEmpty);
    });

    test('short chunk → chunkSizeWrong, nothing left', () async {
      fakeServer.addFile('a.bin', patternBytes(chunkSizeBytes + 5));
      fakeServer.shortChunkIndex = 0;
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'a.bin',
        outputPath: outputPath('a.bin'),
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.chunkSizeWrong,
        ),
      );
      expect(leftFiles(), isEmpty);
    });

    test('wrong whole-file hash → fileHashMismatch, nothing left', () async {
      fakeServer.addFile('a.bin', patternBytes(chunkSizeBytes + 5));
      fakeServer.isFileHashWrong = true;
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'a.bin',
        outputPath: outputPath('a.bin'),
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.fileHashMismatch,
        ),
      );
      expect(leftFiles(), isEmpty);
    });

    test('manifest with the wrong chunk count → badReply', () async {
      fakeServer.server.answer = (request) => request is ReadFile
          ? FileManifest(
              versionId: 1,
              sizeBytes: 10,
              modifiedTimeMs: 0,
              fileSha256: sha256Of([1]),
              chunkHashes: const [],
            )
          : null;
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'a.bin',
        outputPath: outputPath('a.bin'),
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.badReply,
        ),
      );
    });

    test('cancel after 2 of 4 chunks → cancelled, .part removed', () async {
      fakeServer.addFile('a.bin', patternBytes(3 * chunkSizeBytes + 1));
      final cancel = DownloadCancel();
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'a.bin',
        outputPath: outputPath('a.bin'),
        cancel: cancel,
        onProgress: (progress) {
          if (progress.chunksDone == 2) cancel.cancel();
        },
      );
      expect(
        result,
        isA<DownloadCancelled>().having(
          (cancelled) => cancelled.chunksDone,
          'chunksDone',
          2,
        ),
      );
      expect(leftFiles(), isEmpty);
      expect(
        fakeServer.server.sentMessages.whereType<ReadChunk>(),
        hasLength(2),
      );
    });

    test('unknown path → notFound', () async {
      final result = await engine.download(
        deviceId: 0,
        remotePath: 'missing.jpg',
        outputPath: outputPath('missing.jpg'),
      );
      expect(
        result,
        isA<DownloadFailed>()
            .having(
              (failed) => failed.kind,
              'kind',
              DownloadFailureKind.notFound,
            )
            .having((failed) => failed.errorCode, 'errorCode', 40),
      );
      expect(leftFiles(), isEmpty);
    });

    test(
      'missing chunk (ReadChunk NOT_FOUND) → notFound, .part removed',
      () async {
        fakeServer.addFile('a.bin', patternBytes(chunkSizeBytes + 9));
        final realAnswer = fakeServer.server.answer;
        var readChunkCount = 0;
        fakeServer.server.answer = (request) {
          if (request is ReadChunk && ++readChunkCount == 2) {
            return FakeDownloadServer.notFound('chunk gone');
          }
          return realAnswer(request);
        };
        final result = await engine.download(
          deviceId: 0,
          remotePath: 'a.bin',
          outputPath: outputPath('a.bin'),
        );
        expect(
          result,
          isA<DownloadFailed>().having(
            (failed) => failed.kind,
            'kind',
            DownloadFailureKind.notFound,
          ),
        );
        expect(leftFiles(), isEmpty);
      },
    );

    test(
      'connection lost mid-download → connectionLost, .part removed',
      () async {
        fakeServer.addFile('a.bin', patternBytes(2 * chunkSizeBytes + 9));
        final realAnswer = fakeServer.server.answer;
        var readChunkCount = 0;
        fakeServer.server.answer = (request) {
          if (request is ReadChunk && ++readChunkCount == 2) {
            fakeServer.server.link.close();
            return null;
          }
          return realAnswer(request);
        };
        final result = await engine.download(
          deviceId: 0,
          remotePath: 'a.bin',
          outputPath: outputPath('a.bin'),
        );
        expect(
          result,
          isA<DownloadFailed>()
              .having(
                (failed) => failed.kind,
                'kind',
                DownloadFailureKind.connectionLost,
              )
              .having(
                (failed) => failed.connectionFailure,
                'connectionFailure',
                isNotNull,
              ),
        );
        expect(leftFiles(), isEmpty);
      },
    );

    test('existing output is never replaced unless asked', () async {
      fakeServer.addFile('a.txt', Uint8List.fromList('new'.codeUnits));
      File(outputPath('a.txt')).writeAsStringSync('old');
      final refused = await engine.download(
        deviceId: 0,
        remotePath: 'a.txt',
        outputPath: outputPath('a.txt'),
      );
      expect(
        refused,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.outputExists,
        ),
      );
      expect(File(outputPath('a.txt')).readAsStringSync(), 'old');
      expect(fakeServer.server.sentMessages.whereType<ReadFile>(), isEmpty);

      final replaced = await engine.download(
        deviceId: 0,
        remotePath: 'a.txt',
        outputPath: outputPath('a.txt'),
        isOverwriteAllowed: true,
      );
      expect(replaced, isA<DownloadDone>());
      expect(File(outputPath('a.txt')).readAsStringSync(), 'new');
    });

    test('bad remote path → badPath, nothing sent', () async {
      final result = await engine.download(
        deviceId: 0,
        remotePath: '/etc/passwd',
        outputPath: outputPath('x'),
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.badPath,
        ),
      );
      expect(fakeServer.server.sentMessages.whereType<ReadFile>(), isEmpty);
    });
  });

  group('restore to phone', () {
    test('saves under <folder>/device-<id>/<path>, then a free name', () async {
      final content = Uint8List.fromList('photo'.codeUnits);
      fakeServer.addFile('DCIM/IMG_1.jpg', content);
      final restoreFolder = Directory(outputPath('restored'));

      Future<DownloadResult> restore() => restoreToPhone(
        files: engine,
        restoreFolder: restoreFolder,
        deviceId: 1,
        remotePath: 'DCIM/IMG_1.jpg',
      );

      final first = await restore();
      final second = await restore();
      expect(
        (first as DownloadDone).outputPath,
        endsWith('/device-1/DCIM/IMG_1.jpg'),
      );
      expect(
        (second as DownloadDone).outputPath,
        endsWith('/device-1/DCIM/IMG_1 (2).jpg'),
      );
      expect(File(second.outputPath).readAsBytesSync(), content);
    });
  });
}
