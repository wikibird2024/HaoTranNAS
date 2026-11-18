import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/client/nas_connection.dart';
import 'package:haotrannas_mobile/client/upload_engine.dart';
import 'package:haotrannas_mobile/protocol/error_codes.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import 'fake_upload_server.dart';

const remotePath = 'DCIM/Camera/IMG_0001.jpg';
const modifiedTimeMs = 1763450000000;

/// One full chunk filled with [fillByte].
Uint8List fullChunk(int fillByte) =>
    Uint8List(chunkSizeBytes)..fillRange(0, chunkSizeBytes, fillByte);

void main() {
  late Directory temporaryDirectory;
  late FakeUploadServer fakeServer;
  late NasConnection connection;
  late UploadEngine engine;

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync('upload_test');
    fakeServer = FakeUploadServer();
    connection = await NasConnection.open(
      fakeServer.server.link,
      clientSoftware: 'haotrannas-mobile test',
      deviceName: 'test phone',
    );
    engine = UploadEngine(connection);
  });

  tearDown(() async {
    await connection.close();
    temporaryDirectory.deleteSync(recursive: true);
  });

  /// Writes [chunks] one after the other as a local file.
  String writeFile(List<Uint8List> chunks, {String name = 'photo.jpg'}) {
    final builder = BytesBuilder();
    for (final chunk in chunks) {
      builder.add(chunk);
    }
    return (File(
      '${temporaryDirectory.path}/$name',
    )..writeAsBytesSync(builder.toBytes())).path;
  }

  Future<UploadResult> upload(
    String localPath, {
    String remote = remotePath,
    void Function(UploadProgress)? onProgress,
    UploadCancel? cancel,
  }) => engine.upload(
    localPath: localPath,
    remotePath: remote,
    modifiedTimeMs: modifiedTimeMs,
    onProgress: onProgress,
    cancel: cancel,
  );

  List<int> sentChunkIndexes() => [
    for (final chunkData in fakeServer.sentOfType<ChunkData>())
      chunkData.chunkIndex,
  ];

  test('new file: every chunk in order, then Commit', () async {
    final chunks = [
      fullChunk(1),
      fullChunk(2),
      Uint8List.fromList([7, 8, 9]),
    ];
    final localPath = writeFile(chunks);

    final result = await upload(localPath);

    expect(result, isA<UploadUploaded>());
    final uploaded = result as UploadUploaded;
    expect(uploaded.versionId, 1);
    expect(uploaded.chunksSent, 3);
    expect(uploaded.totalChunks, 3);
    expect(uploaded.bytesSent, 2 * chunkSizeBytes + 3);
    expect(result.isBackedUp, isTrue);

    expect(fakeServer.sentMessages.map((message) => message.messageName), [
      'Hello',
      'FileOffer',
      'ChunkData',
      'ChunkData',
      'ChunkData',
      'Commit',
    ]);
    final offer = fakeServer.sentOfType<FileOffer>().single;
    expect(offer.path, remotePath);
    expect(offer.sizeBytes, 2 * chunkSizeBytes + 3);
    expect(offer.modifiedTimeMs, modifiedTimeMs);
    expect(offer.chunkHashes, [
      for (final chunk in chunks) sha256.convert(chunk).bytes,
    ]);
    expect(sentChunkIndexes(), [0, 1, 2]);
    expect(
      fakeServer.latestVersions[remotePath]!.content,
      File(localPath).readAsBytesSync(),
    );
  });

  test('a hash repeated in one file is sent once', () async {
    final localPath = writeFile([fullChunk(5), fullChunk(6), fullChunk(5)]);

    final result = await upload(localPath) as UploadUploaded;

    expect(sentChunkIndexes(), [0, 1]);
    expect(result.chunksSent, 2);
    expect(result.totalChunks, 3);
    expect(
      fakeServer.latestVersions[remotePath]!.content,
      File(localPath).readAsBytesSync(),
    );
  });

  test('already backed up → no ChunkData, no Commit', () async {
    final localPath = writeFile([fullChunk(1), fullChunk(2)]);
    expect(await upload(localPath), isA<UploadUploaded>());
    final sentBefore = fakeServer.sentMessages.length;

    final result = await upload(localPath);

    expect(result, isA<UploadAlreadyBackedUp>());
    expect((result as UploadAlreadyBackedUp).versionId, 1);
    expect(result.isBackedUp, isTrue);
    expect(
      fakeServer.sentMessages
          .skip(sentBefore)
          .map((message) => message.messageName),
      ['FileOffer'],
    );
  });

  test('resume: server misses only [2, 4] → only those are sent', () async {
    final chunks = [for (var fill = 0; fill < 5; fill++) fullChunk(fill)];
    fakeServer.storeChunks([chunks[0], chunks[1], chunks[3]]);
    final localPath = writeFile(chunks);

    final result = await upload(localPath) as UploadUploaded;

    expect(sentChunkIndexes(), [2, 4]);
    expect(result.chunksSent, 2);
    expect(result.bytesSent, 2 * chunkSizeBytes);
    expect(result.totalChunks, 5);
    expect(fakeServer.sentOfType<Commit>(), hasLength(1));
  });

  test(
    'cancel after 2 chunks → no Commit; next upload sends the rest',
    () async {
      final chunks = [for (var fill = 0; fill < 4; fill++) fullChunk(fill)];
      final localPath = writeFile(chunks);
      final cancel = UploadCancel();

      final result = await upload(
        localPath,
        cancel: cancel,
        onProgress: (progress) {
          if (progress.chunksSent == 2) cancel.cancel();
        },
      );

      expect(result, isA<UploadCancelled>());
      expect((result as UploadCancelled).chunksSent, 2);
      expect(result.isBackedUp, isFalse);
      expect(sentChunkIndexes(), [0, 1]);
      expect(fakeServer.sentOfType<Commit>(), isEmpty);
      expect(fakeServer.latestVersions, isEmpty);

      final resumed = await upload(localPath) as UploadUploaded;
      expect(sentChunkIndexes(), [0, 1, 2, 3]);
      expect(resumed.chunksSent, 2);
      expect(fakeServer.sentOfType<FileOffer>(), hasLength(2));
      expect(fakeServer.sentOfType<Commit>(), hasLength(1));
    },
  );

  test('CHUNKS_MISSING on Commit → same offer again → finish', () async {
    final chunks = [fullChunk(1), fullChunk(2), fullChunk(3)];
    final localPath = writeFile(chunks);
    fakeServer
      ..badChunkCommitsLeft = 1
      ..badChunkIndex = 1;

    final result = await upload(localPath) as UploadUploaded;

    expect(fakeServer.sentMessages.map((message) => message.messageName), [
      'Hello',
      'FileOffer',
      'ChunkData',
      'ChunkData',
      'ChunkData',
      'Commit',
      'FileOffer',
      'ChunkData',
      'Commit',
    ]);
    expect(sentChunkIndexes(), [0, 1, 2, 1]);
    final offers = fakeServer.sentOfType<FileOffer>();
    expect(offers[1], offers[0], reason: 'the re-offer is the same offer');
    expect(result.chunksSent, 4);
    expect(result.versionId, 1);
  });

  test(
    'CHUNKS_MISSING on every Commit → chunksStillMissing after 3 offers',
    () async {
      final localPath = writeFile([fullChunk(1)]);
      fakeServer.badChunkCommitsLeft = 99;

      final result = await upload(localPath);

      expect(result, isA<UploadFailed>());
      final failed = result as UploadFailed;
      expect(failed.kind, UploadFailureKind.chunksStillMissing);
      expect(failed.errorCode, ErrorCode.chunksMissing.number);
      expect(fakeServer.sentOfType<FileOffer>(), hasLength(maxOfferRounds));
      expect(fakeServer.sentOfType<Commit>(), hasLength(maxOfferRounds));
    },
  );

  test(
    'file changed after hashing → fileChangedDuringUpload, no Commit',
    () async {
      final localPath = writeFile([fullChunk(1), fullChunk(2), fullChunk(3)]);
      fakeServer.onRequest = (request) {
        if (request is FileOffer) {
          // Someone edits the photo while the offer is on the wire.
          writeFile([fullChunk(1), fullChunk(9), fullChunk(3)]);
        }
      };

      final result = await upload(localPath);

      expect(result, isA<UploadFailed>());
      expect(
        (result as UploadFailed).kind,
        UploadFailureKind.fileChangedDuringUpload,
      );
      expect(sentChunkIndexes(), [
        0,
      ], reason: 'chunk 1 is checked before sending');
      expect(fakeServer.sentOfType<Commit>(), isEmpty);
      expect(connection.isReady, isTrue, reason: 'the connection stays usable');
    },
  );

  test('file got shorter after hashing → fileChangedDuringUpload', () async {
    final localPath = writeFile([fullChunk(1), fullChunk(2)]);
    fakeServer.onRequest = (request) {
      if (request is FileOffer) writeFile([fullChunk(1)]);
    };

    final result = await upload(localPath) as UploadFailed;

    expect(result.kind, UploadFailureKind.fileChangedDuringUpload);
    expect(fakeServer.sentOfType<Commit>(), isEmpty);
  });

  test('ChunkOk with the wrong index → badReply, no Commit', () async {
    final localPath = writeFile([fullChunk(1), fullChunk(2)]);
    fakeServer.replyOverride = (request) => request is ChunkData
        ? ChunkOk(
            chunkIndex: request.chunkIndex + 1,
            chunkSha256: request.chunkSha256,
          )
        : null;

    final result = await upload(localPath) as UploadFailed;

    expect(result.kind, UploadFailureKind.badReply);
    expect(sentChunkIndexes(), [0]);
    expect(fakeServer.sentOfType<Commit>(), isEmpty);
  });

  test('ChunkOk with the wrong hash → badReply', () async {
    final localPath = writeFile([fullChunk(1)]);
    fakeServer.replyOverride = (request) => request is ChunkData
        ? ChunkOk(chunkIndex: request.chunkIndex, chunkSha256: Uint8List(32))
        : null;

    final result = await upload(localPath) as UploadFailed;

    expect(result.kind, UploadFailureKind.badReply);
    expect(fakeServer.sentOfType<Commit>(), isEmpty);
  });

  test('NeedChunks index outside the file → badReply, nothing sent', () async {
    final localPath = writeFile([fullChunk(1)]);
    fakeServer.replyOverride = (request) => request is FileOffer
        ? const NeedChunks(
            uploadId: 5,
            existingVersionId: 0,
            missingIndexes: [1],
          )
        : null;

    final result = await upload(localPath) as UploadFailed;

    expect(result.kind, UploadFailureKind.badReply);
    expect(fakeServer.sentOfType<ChunkData>(), isEmpty);
  });

  test('empty file (0 chunks) → straight to Commit', () async {
    final localPath = writeFile([]);

    final result = await upload(localPath) as UploadUploaded;

    final offer = fakeServer.sentOfType<FileOffer>().single;
    expect(offer.sizeBytes, 0);
    expect(offer.chunkHashes, isEmpty);
    expect(offer.fileSha256, sha256.convert(const <int>[]).bytes);
    expect(fakeServer.sentMessages.map((message) => message.messageName), [
      'Hello',
      'FileOffer',
      'Commit',
    ]);
    expect(result.chunksSent, 0);
    expect(result.totalChunks, 0);
  });

  test('progress: one call per confirmed chunk, counts add up', () async {
    final localPath = writeFile([
      fullChunk(1),
      fullChunk(2),
      Uint8List.fromList([1, 2, 3, 4, 5]),
    ]);
    final progressList = <UploadProgress>[];

    await upload(localPath, onProgress: progressList.add);

    expect(
      [for (final progress in progressList) progress.chunksSent],
      [1, 2, 3],
    );
    expect(
      [for (final progress in progressList) progress.bytesSent],
      [chunkSizeBytes, 2 * chunkSizeBytes, 2 * chunkSizeBytes + 5],
    );
    for (final progress in progressList) {
      expect(progress.chunksToSend, 3);
      expect(progress.totalChunks, 3);
      expect(progress.sizeBytes, 2 * chunkSizeBytes + 5);
    }
  });

  test('bad remote path → badPath, nothing offered', () async {
    final localPath = writeFile([fullChunk(1)]);

    final result =
        await upload(localPath, remote: '/DCIM/../x.jpg') as UploadFailed;

    expect(result.kind, UploadFailureKind.badPath);
    expect(fakeServer.sentOfType<FileOffer>(), isEmpty);
  });

  test('server errors become typed failures', () async {
    final localPath = writeFile([fullChunk(1)]);
    final cases = {
      ErrorCode.badPath: UploadFailureKind.badPath,
      ErrorCode.tooLarge: UploadFailureKind.tooLarge,
      ErrorCode.diskFull: UploadFailureKind.diskFull,
      ErrorCode.internal: UploadFailureKind.serverRejected,
    };
    for (final MapEntry(key: code, value: kind) in cases.entries) {
      fakeServer.replyOverride = (request) => request is ChunkData
          ? ErrorMessage(code: code.number, message: 'test')
          : null;
      final result = await upload(localPath) as UploadFailed;
      expect(result.kind, kind, reason: code.wireName);
      expect(result.errorCode, code.number);
    }
    expect(fakeServer.sentOfType<Commit>(), isEmpty);
  });

  test('missing local file → fileUnreadable', () async {
    final result =
        await upload('${temporaryDirectory.path}/gone.jpg') as UploadFailed;

    expect(result.kind, UploadFailureKind.fileUnreadable);
    expect(fakeServer.sentOfType<FileOffer>(), isEmpty);
  });

  test('server closes during the upload → connectionLost', () async {
    final localPath = writeFile([fullChunk(1), fullChunk(2)]);
    fakeServer.replyOverride = (request) => request is ChunkData
        ? Close(reason: CloseReason.serverShutdown.number, message: 'bye')
        : null;

    final result = await upload(localPath) as UploadFailed;

    expect(result.kind, UploadFailureKind.connectionLost);
    expect(result.connectionFailure!.kind, NasFailureKind.serverClosed);
    expect(fakeServer.sentOfType<Commit>(), isEmpty);
  });
}
