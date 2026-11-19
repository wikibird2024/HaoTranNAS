// M7 "Done when" against a real haotrannas-server in TLS mode: pair with
// a code from the admin socket, back up a PC folder with the app's
// FolderMediaSource + BackupRunner, restore the whole folder and compare
// every SHA-256; then the admin commands (devices, scrub, cleanup,
// revoke). e2e/scripts/desktop_vs_server.sh sets:
//   NAS_TLS_SERVER_ADDR  ip:port of the TLS listener
//   NAS_TLS_DATA_DIR     its --data-dir (admin.sock is inside)
// Without both every test is skipped. Author: Hao Tran.
@Tags(['server'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/app/client_providers.dart'
    show connectPairedOrThrow;
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/client/address_book.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/pairing.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_desktop/admin/admin_codec.dart';
import 'package:haotrannas_desktop/admin/admin_link.dart';
import 'package:haotrannas_desktop/backup/folder_media_source.dart';
import 'package:haotrannas_desktop/files/restore.dart';

const clientSoftware = 'haotrannas-desktop integration test';

T okValue<T>(AdminResult<T> result) => switch (result) {
  AdminOk(:final value) => value,
  AdminFailed(:final message) => fail('admin said: $message'),
};

void main() {
  final environment = Platform.environment;
  final serverAddressText = environment['NAS_TLS_SERVER_ADDR'];
  final dataDirectory = environment['NAS_TLS_DATA_DIR'];
  final skipReason = (serverAddressText == null || dataDirectory == null)
      ? 'NAS_TLS_SERVER_ADDR and NAS_TLS_DATA_DIR not set '
            '(run e2e/scripts/desktop_vs_server.sh)'
      : null;
  final runStamp = DateTime.now().millisecondsSinceEpoch;
  final deviceName = 'desktop test $runStamp';
  final folderName = 'PcFolder$runStamp';
  final random = Random.secure();

  late AdminLink admin;
  late Directory work;
  late Directory pcFolder;
  late DeviceIdentity identity;
  late AddressBook addressBook;

  Uint8List randomBytes(int sizeBytes) {
    final bytes = Uint8List(sizeBytes);
    for (var index = 0; index < sizeBytes; index++) {
      bytes[index] = random.nextInt(256);
    }
    return bytes;
  }

  /// Path inside the folder → SHA-256 hex of every file under [folder].
  Map<String, String> hashesUnder(Directory folder) => {
    for (final file in folder.listSync(recursive: true).whereType<File>())
      file.path.substring(folder.path.length + 1): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };

  setUpAll(() async {
    if (skipReason != null) return;
    admin = AdminLink('$dataDirectory/admin.sock');
    work = Directory.systemTemp.createTempSync('desktop_vs_server');
    pcFolder = Directory('${work.path}/$folderName');
    File('${pcFolder.path}/notes/deep/a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('hello from the PC');
    File('${pcFolder.path}/Tiếng Việt.txt').writeAsStringSync('chào');
    File('${pcFolder.path}/empty.bin').writeAsBytesSync(const []);
    File('${pcFolder.path}/big.bin').writeAsBytesSync(randomBytes(20 << 20));
    Link('${pcFolder.path}/link').createSync('${pcFolder.path}/big.bin');

    // Pair with a code from the admin socket, like "Pair in one click".
    final code = okValue(parsePair(await admin.send(AdminCommand.pair)));
    final server = ServerAddress.tryParse(serverAddressText!)!;
    final paired = await pairWithServer(
      host: server.host,
      port: server.port,
      code: code.code,
      deviceName: deviceName,
      clientSoftware: clientSoftware,
    );
    expect(paired, isA<PairingSucceeded>(), reason: '$paired');
    final succeeded = paired as PairingSucceeded;
    expect(
      succeeded.serverShortId,
      code.serverShortId,
      reason: 'the admin socket and the TLS connection see the same server',
    );
    identity = succeeded.identity.withAddresses(
      KnownAddresses(lastLan: server),
    );
    addressBook = AddressBook(
      clientSoftware: clientSoftware,
      deviceName: deviceName,
    );
  });

  tearDownAll(() {
    if (skipReason != null) return;
    work.deleteSync(recursive: true);
  });

  group('desktop app against the real server', skip: skipReason, () {
    late BackupRunner runner;

    setUpAll(() {
      if (skipReason != null) return;
      runner = BackupRunner(
        mediaSource: FolderMediaSource(
          chosenFolderPaths: () => {pcFolder.path},
        ),
        stateStore: MemoryBackupStateStore(),
        connect: () => connectPairedOrThrow(addressBook, identity),
      );
    });

    test('backs up the PC folder; a second run sends nothing', () async {
      final first = await runner.runOnce(folderIds: {pcFolder.path});
      expect(first.failures, isEmpty, reason: '${first.failures}');
      expect(first.stopReason, BackupStopReason.finished);
      expect(first.filesUploaded, 4, reason: 'symlink skipped');
      expect(first.bytesUploaded, greaterThan(20 << 20));

      final second = await runner.runOnce(folderIds: {pcFolder.path});
      expect(second.filesUploaded, 0);
      expect(second.failures, isEmpty);
    });

    test('restores the whole folder; every SHA-256 matches (M7)', () async {
      final connection = await connectPairedOrThrow(addressBook, identity);
      addTearDown(connection.close);
      final target = Directory('${work.path}/restored')..createSync();
      final summary = await restoreFolder(
        files: DownloadEngine(connection),
        deviceId: 0,
        remoteFolder: folderName,
        targetFolder: target,
      );
      expect(summary.isComplete, isTrue, reason: '${summary.failures}');
      expect(summary.filesRestored, 4);
      final original = hashesUnder(pcFolder)..remove('link');
      expect(hashesUnder(Directory('${target.path}/$folderName')), original);
    });

    test('admin: status, devices, scrub clean, cleanup', () async {
      expect(
        okValue(parseStatus(await admin.send(AdminCommand.status))),
        isNonNegative,
      );
      final devices = okValue(
        parseDevices(await admin.send(AdminCommand.devices)),
      );
      final ours = devices.singleWhere((device) => device.name == deviceName);
      expect(ours.id, identity.deviceId);
      expect(ours.isRevoked, isFalse);

      final progress = <int>[];
      final scrub = okValue(
        parseJobSummary(
          await admin.send(AdminCommand.scrubNow, onProgress: progress.add),
          'scrub',
        ),
      );
      expect(scrub.isClean, isTrue);
      expect(scrub.chunksChecked, greaterThanOrEqualTo(21));
      final report = okValue(
        parseJobSummary(await admin.send(AdminCommand.scrubReport), 'scrub'),
      );
      expect(report.chunksChecked, scrub.chunksChecked);
      okValue(
        parseJobSummary(await admin.send(AdminCommand.cleanupNow), 'cleanup'),
      );
    });

    test('admin: revoke locks this device out, its backup stays', () async {
      expect(
        okValue(
          parseRevoke(await admin.send(AdminCommand.revoke(identity.deviceId))),
        ),
        identity.deviceId,
      );
      await expectLater(
        connectPairedOrThrow(addressBook, identity),
        throwsA(isA<BackupConnectFailed>()),
      );
      final devices = okValue(
        parseDevices(await admin.send(AdminCommand.devices)),
      );
      expect(
        devices
            .singleWhere((device) => device.id == identity.deviceId)
            .isRevoked,
        isTrue,
      );
    });
  });
}
