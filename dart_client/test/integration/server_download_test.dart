// Browse and download (spec §9) against a real haotrannas-server in TLS
// mode: pair, upload a small tree with UploadEngine, list it with
// paging, download every file and compare bytes. Same set-up as
// server_tls_test.dart (e2e/scripts/flutter_vs_server.sh sets):
//   NAS_TLS_SERVER_ADDR  ip:port of the TLS listener
//   NAS_TLS_DATA_DIR     its --data-dir (for `haotrannas-server pair`)
//   NAS_SERVER_BIN       the server binary
// Without all three every test is skipped. Author: Hao Tran.
@Tags(['server'])
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/address_book.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/client/pairing.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/client/upload_engine.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/messages.dart';

const clientSoftware = 'haotrannas-mobile integration test';

void main() {
  final environment = Platform.environment;
  final serverAddressText = environment['NAS_TLS_SERVER_ADDR'];
  final dataDirectory = environment['NAS_TLS_DATA_DIR'];
  final serverBinary = environment['NAS_SERVER_BIN'];
  final skipReason =
      (serverAddressText == null ||
          dataDirectory == null ||
          serverBinary == null)
      ? 'NAS_TLS_SERVER_ADDR, NAS_TLS_DATA_DIR and NAS_SERVER_BIN not all '
            'set (run e2e/scripts/flutter_vs_server.sh)'
      : null;
  final runStamp = DateTime.now().millisecondsSinceEpoch;
  final random = Random.secure();
  final treeRoot = 'dart-download-$runStamp';

  /// Remote path → content of the uploaded tree.
  final tree = <String, Uint8List>{};

  late Directory temporaryDirectory;
  late NasConnection connection;
  late DownloadEngine engine;

  Uint8List randomBytes(int sizeBytes) {
    final bytes = Uint8List(sizeBytes);
    for (var index = 0; index < sizeBytes; index++) {
      bytes[index] = random.nextInt(256);
    }
    return bytes;
  }

  setUpAll(() async {
    if (skipReason != null) return;
    temporaryDirectory = Directory.systemTemp.createTempSync('server_download');
    final server = ServerAddress.tryParse(serverAddressText!)!;

    // Pair as a new device.
    final pairOutput = await Process.run(serverBinary!, [
      'pair',
      '--data-dir',
      dataDirectory!,
    ]).timeout(const Duration(seconds: 20));
    final pairText = '${pairOutput.stdout}';
    final code = RegExp(r'code (\d{6})').firstMatch(pairText)?.group(1);
    expect(code, isNotNull, reason: 'no code in: $pairText');
    final paired = await pairWithServer(
      host: server.host,
      port: server.port,
      code: code!,
      deviceName: 'download test $runStamp',
      clientSoftware: clientSoftware,
    );
    expect(paired, isA<PairingSucceeded>(), reason: '$paired');
    final identity = (paired as PairingSucceeded).identity.withAddresses(
      KnownAddresses(lastLan: server),
    );
    final connected = await AddressBook(
      clientSoftware: clientSoftware,
      deviceName: 'download test $runStamp',
    ).connectPaired(identity);
    expect(connected, isA<PairedConnected>(), reason: '$connected');
    connection = (connected as PairedConnected).connection;
    engine = DownloadEngine(connection);

    // Upload a small tree: 5 files at the top (pages of 2), a sub folder
    // with a 2-chunk file.
    for (var index = 0; index < 5; index++) {
      tree['$treeRoot/file-$index.txt'] = randomBytes(100 + index);
    }
    tree['$treeRoot/sub/two-chunks.bin'] = randomBytes(chunkSizeBytes + 33);
    final uploader = UploadEngine(connection);
    for (final (fileIndex, MapEntry(key: remotePath, value: content))
        in tree.entries.indexed) {
      final localFile = File('${temporaryDirectory.path}/upload-$fileIndex')
        ..writeAsBytesSync(content);
      final uploaded = await uploader.upload(
        localPath: localFile.path,
        remotePath: remotePath,
        modifiedTimeMs: runStamp,
      );
      expect(uploaded, isA<UploadUploaded>(), reason: '$remotePath: $uploaded');
    }
  });

  tearDownAll(() async {
    if (skipReason != null) return;
    await connection.close();
    temporaryDirectory.deleteSync(recursive: true);
  });

  group('TLS server browse + download', skip: skipReason, () {
    test('ListDevices marks this phone', () async {
      final devices = await engine.listDevices();
      final me = devices.where((device) => device.isCaller).toList();
      expect(me, hasLength(1));
      expect(me.single.deviceId, connection.helloOk.deviceId);
    });

    test('ListDir pages of 2 list the tree, folders implied', () async {
      final top = await engine.listDirAll(
        deviceId: 0,
        path: treeRoot,
        pageSize: 2,
      );
      expect(
        [for (final entry in top) entry.name],
        [
          'file-0.txt',
          'file-1.txt',
          'file-2.txt',
          'file-3.txt',
          'file-4.txt',
          'sub',
        ],
      );
      final sub = top.last;
      expect(sub.kind, DirEntryKind.directory);
      expect(sub.versionId, 0);
      expect(top.first.sizeBytes, 100);
      expect(top.first.modifiedTimeMs, runStamp);
      expect(top.first.versionId, isNot(0));
    });

    test('every file downloads byte-equal', () async {
      Future<void> walk(String path) async {
        for (final entry in await engine.listDirAll(deviceId: 0, path: path)) {
          final childPath = '$path/${entry.name}';
          if (entry.kind == DirEntryKind.directory) {
            await walk(childPath);
            continue;
          }
          final outputPath =
              '${temporaryDirectory.path}/out/${childPath.replaceAll('/', '_')}';
          final result = await engine.download(
            deviceId: 0,
            remotePath: childPath,
            versionId: entry.versionId,
            outputPath: outputPath,
          );
          expect(result, isA<DownloadDone>(), reason: '$childPath: $result');
          expect(
            File(outputPath).readAsBytesSync(),
            tree[childPath],
            reason: '$childPath bytes',
          );
          expect(File('$outputPath$partFileSuffix').existsSync(), isFalse);
        }
      }

      await walk(treeRoot);
      final downloaded = Directory('${temporaryDirectory.path}/out')
          .listSync()
          .length;
      expect(downloaded, tree.length);
    });

    test('unknown path and folder → NOT_FOUND', () async {
      final result = await engine.download(
        deviceId: 0,
        remotePath: '$treeRoot/missing.txt',
        outputPath: '${temporaryDirectory.path}/missing.txt',
      );
      expect(
        result,
        isA<DownloadFailed>().having(
          (failed) => failed.kind,
          'kind',
          DownloadFailureKind.notFound,
        ),
      );
      await expectLater(
        engine.listDirPage(deviceId: 0, path: '$treeRoot/nope'),
        throwsA(
          isA<BrowseFailed>().having(
            (failed) => failed.kind,
            'kind',
            BrowseFailureKind.notFound,
          ),
        ),
      );
    });
  });
}
