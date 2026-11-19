// Dart ⇄ rustls mutual TLS against a real haotrannas-server in TLS mode
// (spec §1, §6, §7). e2e/scripts/flutter_vs_server.sh starts one and
// sets:
//   NAS_TLS_SERVER_ADDR  ip:port of the TLS listener
//   NAS_TLS_DATA_DIR     its --data-dir (for `haotrannas-server pair`)
//   NAS_SERVER_BIN       the server binary
// The server must allow pairing from this address (loopback).
// Without all three every test is skipped.
@Tags(['server'])
@Timeout(Duration(seconds: 90))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/address_book.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/client/pairing.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/client/upload_engine.dart';
import 'package:haotrannas_client/core/transport/tls_link.dart';
import 'package:haotrannas_client/protocol/error_codes.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/testing/tls_test_certificates.dart';

const clientSoftware = 'haotrannas-mobile integration test';

/// What `haotrannas-server pair` printed.
typedef PairingWindow = ({String code, String serverShortId});

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

  late ServerAddress server;
  late Directory temporaryDirectory;

  setUpAll(() {
    if (skipReason != null) return;
    server = ServerAddress.tryParse(serverAddressText!)!;
    temporaryDirectory = Directory.systemTemp.createTempSync('server_tls');
  });

  tearDownAll(() {
    if (skipReason != null) return;
    temporaryDirectory.deleteSync(recursive: true);
  });

  /// Opens a pairing window with `haotrannas-server pair`; output like
  /// `code 482913 · server id 3F9A-C21B-77E0 · valid 120 s`.
  Future<PairingWindow> openPairingWindow() async {
    final result = await Process.run(serverBinary!, [
      'pair',
      '--data-dir',
      dataDirectory!,
    ]).timeout(const Duration(seconds: 20));
    final output = '${result.stdout}';
    printOnFailure('pair: exit ${result.exitCode}\n$output${result.stderr}');
    expect(result.exitCode, 0);
    final code = RegExp(r'code (\d{6})').firstMatch(output)?.group(1);
    final shortIdText = RegExp(
      r'server id ([0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4})',
    ).firstMatch(output)?.group(1);
    expect(code, isNotNull, reason: 'no code in: $output');
    expect(shortIdText, isNotNull, reason: 'no server id in: $output');
    return (code: code!, serverShortId: shortIdText!);
  }

  Future<PairingResult> pair(String code, {String? expectedShortId}) =>
      pairWithServer(
        host: server.host,
        port: server.port,
        code: code,
        deviceName: 'tls test $runStamp',
        clientSoftware: clientSoftware,
        expectedShortId: expectedShortId,
      );

  String writeRandomFile(String name, int sizeBytes) {
    final bytes = Uint8List(sizeBytes);
    for (var index = 0; index < sizeBytes; index++) {
      bytes[index] = random.nextInt(256);
    }
    return (File(
      '${temporaryDirectory.path}/$name',
    )..writeAsBytesSync(bytes)).path;
  }

  group('TLS server', skip: skipReason, () {
    test('wrong code → BAD_PAIRING_CODE, 2 tries left', () async {
      final window = await openPairingWindow();
      final wrongCode = window.code == '000000' ? '000001' : '000000';
      final result = await pair(wrongCode);
      printOnFailure('$result');
      expect(
        result,
        isA<PairingFailed>()
            .having((failed) => failed.kind, 'kind', PairingFailureKind.badCode)
            .having((failed) => failed.attemptsLeft, 'attemptsLeft', 2),
      );
    });

    test('pair → save/load → reconnect with mTLS → ping → upload → '
        'already backed up', () async {
      final window = await openPairingWindow();
      final result = await pair(
        window.code,
        expectedShortId: window.serverShortId,
      );
      printOnFailure('pairing: $result');
      expect(result, isA<PairingSucceeded>());
      final paired = result as PairingSucceeded;
      expect(paired.serverShortId, window.serverShortId);
      expect(paired.identity.deviceId, greaterThan(0));

      // The real certificate and key survive the store.
      final store = IdentityStore(temporaryDirectory);
      await store.save(
        paired.identity.withAddresses(KnownAddresses(lastLan: server)),
      );
      final identity = (await store.load())!;

      final book = AddressBook(
        clientSoftware: clientSoftware,
        deviceName: 'tls test $runStamp',
        store: store,
      );
      final connected = await book.connectPaired(identity);
      printOnFailure('connect: $connected');
      expect(connected, isA<PairedConnected>());
      final connection = (connected as PairedConnected).connection;
      addTearDown(connection.close);
      expect(connection.helloOk.deviceId, identity.deviceId);

      await connection.ping();

      final engine = UploadEngine(connection);
      final localPath = writeRandomFile('tls.bin', 70000);
      final remotePath = 'dart/tls-$runStamp.bin';
      final uploaded = await engine.upload(
        localPath: localPath,
        remotePath: remotePath,
        modifiedTimeMs: runStamp,
      );
      printOnFailure('upload: $uploaded');
      expect(uploaded, isA<UploadUploaded>());

      final again = await engine.upload(
        localPath: localPath,
        remotePath: remotePath,
        modifiedTimeMs: runStamp,
      );
      printOnFailure('second upload: $again');
      expect(again, isA<UploadAlreadyBackedUp>());
    });

    test('wrong pin → TlsPinMismatch', () async {
      final wrongPin = FixedServerPin(sha256.convert([1, 2, 3]).bytes);
      await expectLater(
        TlsLink.connect(server.host, server.port, pin: wrongPin),
        throwsA(isA<TlsPinMismatch>()),
      );
    });

    test(
      'no client certificate: HelloOk device 0, FileOffer → NOT_PAIRED',
      () async {
        final link = await TlsLink.connect(
          server.host,
          server.port,
          pin: TrustOnFirstUsePin(),
        );
        final connection = await NasConnection.open(
          link,
          clientSoftware: clientSoftware,
          deviceName: 'unpaired',
        );
        addTearDown(connection.close);
        expect(connection.helloOk.deviceId, 0);
        final content = Uint8List.fromList([42]);
        final contentSha256 = Uint8List.fromList(sha256.convert(content).bytes);
        await expectLater(
          connection.request(
            FileOffer(
              path: 'dart/unpaired-$runStamp.bin',
              sizeBytes: 1,
              modifiedTimeMs: runStamp,
              fileSha256: contentSha256,
              chunkHashes: [contentSha256],
            ),
          ),
          throwsA(
            isA<NasRequestError>().having(
              (error) => error.code,
              'code',
              ErrorCode.notPaired.number,
            ),
          ),
        );
      },
    );

    test(
      'certificate the server never issued: refused before HelloOk '
      '(maybe not paired)',
      skip: TlsTestCertificates.skipReason,
      () async {
        final certificates = await TlsTestCertificates.create();
        addTearDown(certificates.delete);
        // A pin to the real server, a device certificate from a stranger CA.
        final probe = TrustOnFirstUsePin();
        await (await TlsLink.connect(
          server.host,
          server.port,
          pin: probe,
        )).close();
        final stranger = DeviceIdentity(
          deviceId: 1,
          certDer: certificates.device.der,
          keyPkcs8Der: certificates.deviceKeyPkcs8Der,
          serverCertSha256: probe.seenFingerprint!,
          lastAddresses: KnownAddresses(lastLan: server),
        );
        final result = await AddressBook(
          clientSoftware: clientSoftware,
          deviceName: 'stranger',
        ).connectPaired(stranger);
        printOnFailure('$result');
        expect(
          result,
          isA<PairedConnectFailed>().having(
            (failed) => failed.kind,
            'kind',
            PairedConnectFailureKind.maybeNotPaired,
          ),
        );
      },
    );
  });
}
