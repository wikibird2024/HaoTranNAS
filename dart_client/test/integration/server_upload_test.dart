// Uploads to a real haotrannas-server in dev mode (plain TCP, every
// connection is device 1). Start one, then:
//   NAS_SERVER_ADDR=127.0.0.1:47100 flutter test --tags server
// With NAS_SERVER_BIN and NAS_DATA_DIR also set, the first file is
// restored with `haotrannas-server restore` and compared byte for byte.
// Without NAS_SERVER_ADDR every test is skipped.
@Tags(['server'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/client/upload_engine.dart';
import 'package:haotrannas_client/core/transport/tcp_link.dart';
import 'package:haotrannas_client/protocol/limits.dart';

void main() {
  final environment = Platform.environment;
  final serverAddress = environment['NAS_SERVER_ADDR'];
  final serverBinary = environment['NAS_SERVER_BIN'];
  final dataDirectory = environment['NAS_DATA_DIR'];
  final runStamp = DateTime.now().millisecondsSinceEpoch;
  final random = Random.secure();

  late Directory temporaryDirectory;
  late NasConnection connection;
  late UploadEngine engine;

  setUp(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync('server_upload');
    final separatorIndex = serverAddress!.lastIndexOf(':');
    final link = await TcpLink.connect(
      serverAddress.substring(0, separatorIndex),
      int.parse(serverAddress.substring(separatorIndex + 1)),
    );
    connection = await NasConnection.open(
      link,
      clientSoftware: 'haotrannas-mobile integration test',
      deviceName: 'integration test',
    );
    engine = UploadEngine(connection);
  });

  tearDown(() async {
    await connection.close();
    temporaryDirectory.deleteSync(recursive: true);
  });

  /// A local file of [sizeBytes] random bytes, so no earlier run has
  /// stored its chunks.
  String writeRandomFile(String name, int sizeBytes) {
    final bytes = Uint8List(sizeBytes);
    for (var index = 0; index < sizeBytes; index++) {
      bytes[index] = random.nextInt(256);
    }
    return (File(
      '${temporaryDirectory.path}/$name',
    )..writeAsBytesSync(bytes)).path;
  }

  Future<UploadResult> upload(
    String localPath,
    String remotePath, {
    UploadCancel? cancel,
    void Function(UploadProgress)? onProgress,
  }) => engine.upload(
    localPath: localPath,
    remotePath: remotePath,
    modifiedTimeMs: runStamp,
    cancel: cancel,
    onProgress: onProgress,
  );

  final skipReason = serverAddress == null
      ? 'NAS_SERVER_ADDR not set (host:port of haotrannas-server '
            '--dev-plain, e.g. 127.0.0.1:47100)'
      : null;

  group('dev server upload', skip: skipReason, () {
    test('3 MiB + 17 B: upload, then re-upload = already backed up', () async {
      const sizeBytes = 3 * chunkSizeBytes + 17;
      final localPath = writeRandomFile('first.bin', sizeBytes);
      final remotePath = 'dart/test-$runStamp.bin';

      final result = await upload(localPath, remotePath);
      printOnFailure('first upload: $result');
      expect(result, isA<UploadUploaded>());
      final uploaded = result as UploadUploaded;
      expect(uploaded.chunksSent, 4);
      expect(uploaded.totalChunks, 4);
      expect(uploaded.bytesSent, sizeBytes);
      expect(uploaded.versionId, isNot(0));

      final again = await upload(localPath, remotePath);
      printOnFailure('second upload: $again');
      expect(again, isA<UploadAlreadyBackedUp>());
      expect((again as UploadAlreadyBackedUp).versionId, uploaded.versionId);
    });

    test(
      '3 MiB + 17 B: upload, `haotrannas-server restore` gives the same bytes',
      () async {
        const sizeBytes = 3 * chunkSizeBytes + 17;
        final localPath = writeRandomFile('restore.bin', sizeBytes);
        final remotePath = 'dart/restore-$runStamp.bin';

        final result = await upload(localPath, remotePath);
        printOnFailure('upload: $result');
        expect(result, isA<UploadUploaded>());

        final restoredPath = '${temporaryDirectory.path}/restored.bin';
        final restore = await Process.run(serverBinary!, [
          'restore',
          '--data-dir',
          dataDirectory!,
          '--device-id',
          '1',
          '--path',
          remotePath,
          '--output',
          restoredPath,
        ]);
        printOnFailure('restore stdout: ${restore.stdout}');
        printOnFailure('restore stderr: ${restore.stderr}');
        expect(restore.exitCode, 0);
        expect(
          File(restoredPath).readAsBytesSync(),
          File(localPath).readAsBytesSync(),
          reason: 'restored bytes must equal the uploaded file',
        );
      },
      skip: serverBinary == null || dataDirectory == null
          ? 'NAS_SERVER_BIN or NAS_DATA_DIR not set (restore check)'
          : false,
    );

    test('resume: cancel after 2 of 5 chunks, then upload sends 3; same '
        'content at another path sends 0', () async {
      final localPath = writeRandomFile('resume.bin', 4 * chunkSizeBytes + 100);
      final remotePath = 'dart/resume-$runStamp.bin';
      final cancel = UploadCancel();

      final cancelled = await upload(
        localPath,
        remotePath,
        cancel: cancel,
        onProgress: (progress) {
          if (progress.chunksSent == 2) cancel.cancel();
        },
      );
      printOnFailure('cancelled upload: $cancelled');
      expect(cancelled, isA<UploadCancelled>());
      expect((cancelled as UploadCancelled).chunksSent, 2);

      final resumed = await upload(localPath, remotePath);
      printOnFailure('resumed upload: $resumed');
      expect(resumed, isA<UploadUploaded>());
      expect((resumed as UploadUploaded).chunksSent, 3);
      expect(resumed.totalChunks, 5);

      final copy = await upload(localPath, 'dart/copy-$runStamp.bin');
      printOnFailure('copy upload: $copy');
      expect(copy, isA<UploadUploaded>());
      expect((copy as UploadUploaded).chunksSent, 0);
      expect(copy.versionId, isNot(resumed.versionId));
    });
  });
}
