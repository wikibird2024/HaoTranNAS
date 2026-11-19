import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/client/identity.dart';
import 'package:haotrannas_mobile/client/pairing.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/core/transport/tls_link.dart';
import 'package:haotrannas_mobile/protocol/error_codes.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import 'fake_server.dart';
import 'fake_tls_server.dart';

const goodCode = '482913';
final deviceCertDer = Uint8List.fromList(List.generate(300, (index) => index));
final deviceKeyDer = Uint8List.fromList(
  List.generate(138, (index) => 0xA0 ^ index),
);

const unpairedHelloOk = HelloOk(
  protocolVersion: 1,
  serverSoftware: 'haotrannas-server 0.1.0',
  serverName: 'nas',
  deviceId: 0,
  chunkSizeBytes: 1048576,
  maxFrameLengthBytes: 4194304,
);

PairOk pairOkFor(Uint8List serverFingerprint) => PairOk(
  deviceId: 7,
  deviceCertDer: deviceCertDer,
  deviceKeyPkcs8Der: deviceKeyDer,
  serverCertSha256: serverFingerprint,
);

ErrorMessage errorFor(ErrorCode code) =>
    ErrorMessage(code: code.number, message: code.wireName.toLowerCase());

/// A pairing server: HelloOk(device 0); the right code gets PairOk and
/// then Close(PAIRED_RECONNECT); [onWrongCode] answers other codes.
FakeTlsServer pairingServer({
  Message Function(int failures)? onWrongCode,
  PairOk? pairOk,
  bool sendsClose = true,
}) {
  final fake = FakeTlsServer();
  var failures = 0;
  fake.answer = (server, host, request) {
    switch (request) {
      case Hello():
        return unpairedHelloOk;
      case PairRequest(:final code) when code == goodCode:
        if (sendsClose) {
          sendLater(
            server,
            Close(reason: CloseReason.pairedReconnect.number, message: ''),
          );
        }
        return pairOk ?? pairOkFor(testServerFingerprint);
      case PairRequest():
        failures++;
        return (onWrongCode ?? (_) => errorFor(ErrorCode.badPairingCode))(
          failures,
        );
      default:
        return FakeServer.defaultAnswer(request);
    }
  };
  return fake;
}

Future<PairingResult> pair(
  FakeTlsServer fake, {
  String code = goodCode,
  String? expectedShortId,
}) => pairWithServer(
  host: '192.168.1.5',
  port: 47100,
  code: code,
  deviceName: 'test phone',
  clientSoftware: 'haotrannas-mobile test',
  expectedShortId: expectedShortId,
  connect: fake.connect,
);

Future<PairingSession> openSession(FakeTlsServer fake) => PairingSession.open(
  host: '192.168.1.5',
  port: 47100,
  deviceName: 'test phone',
  clientSoftware: 'haotrannas-mobile test',
  connect: fake.connect,
);

Matcher failedWith(PairingFailureKind kind) =>
    isA<PairingFailed>().having((failed) => failed.kind, 'kind', kind);

void main() {
  group('success', () {
    test(
      'TOFU, no client cert, Hello → PairRequest → PairOk → Close',
      () async {
        final fake = pairingServer();
        final result = await pair(fake);

        expect(result, isA<PairingSucceeded>());
        final succeeded = result as PairingSucceeded;
        expect(succeeded.serverShortId, shortId(testServerFingerprint));
        final identity = succeeded.identity;
        expect(identity.deviceId, 7);
        expect(identity.certDer, deviceCertDer);
        expect(identity.keyPkcs8Der, deviceKeyDer);
        expect(identity.serverCertSha256, testServerFingerprint);

        final call = fake.calls.single;
        expect(call.host, '192.168.1.5');
        expect(call.port, 47100);
        expect(call.pin, isA<TrustOnFirstUsePin>());
        expect(call.clientCertificate, isNull);
        expect(fake.lastServer.sentMessages, [
          isA<Hello>(),
          const PairRequest(code: goodCode),
        ]);
        expect(fake.lastServer.link.isClosed, isTrue);
      },
    );

    test('the result never prints the key', () async {
      final result = await pair(pairingServer());
      final text = result.toString();
      expect(text, contains('<key redacted>'));
      expect(text, isNot(contains(toHex(deviceKeyDer.sublist(0, 8)))));
    });

    test('matching short id typed by the user (any case, no dashes)', () async {
      final typed = shortId(testServerFingerprint)
          .replaceAll('-', '')
          .toLowerCase();
      expect(
        await pair(pairingServer(), expectedShortId: typed),
        isA<PairingSucceeded>(),
      );
    });

    test('server does not send Close: still paired, closed by us', () async {
      final fake = pairingServer(sendsClose: false);
      final result = await pair(fake);
      expect(result, isA<PairingSucceeded>());
      expect(fake.lastServer.link.isClosed, isTrue);
    });
  });

  group('stops before trusting', () {
    test('PairOk names another server certificate: serverMismatch', () async {
      final fake = pairingServer(pairOk: pairOkFor(sha256Of([1, 2, 3])));
      final result = await pair(fake);
      expect(result, failedWith(PairingFailureKind.serverMismatch));
      expect((result as PairingFailed).message, contains('in the middle'));
      expect(fake.lastServer.link.isClosed, isTrue);
    });

    test('short id mismatch: code never sent', () async {
      final fake = pairingServer();
      final result = await pair(fake, expectedShortId: '0000-0000-0000');
      expect(result, failedWith(PairingFailureKind.shortIdMismatch));
      expect(fake.lastServer.sentMessages.whereType<PairRequest>(), isEmpty);
    });

    test('code not 6 digits: no connection at all', () async {
      final fake = pairingServer();
      for (final code in ['12345', '1234567', '12a456', ' 482913', '']) {
        expect(
          await pair(fake, code: code),
          failedWith(PairingFailureKind.badCodeFormat),
          reason: code,
        );
      }
      expect(fake.calls, isEmpty);
    });

    test('HelloOk with a device id: badReply', () async {
      final fake = pairingServer();
      fake.answer = (server, host, request) =>
          request is Hello ? testHelloOk : null;
      expect(await pair(fake), failedWith(PairingFailureKind.badReply));
    });

    test('PairOk with an empty certificate: badReply', () async {
      final fake = pairingServer(
        pairOk: PairOk(
          deviceId: 7,
          deviceCertDer: Uint8List(0),
          deviceKeyPkcs8Der: deviceKeyDer,
          serverCertSha256: testServerFingerprint,
        ),
      );
      expect(await pair(fake), failedWith(PairingFailureKind.badReply));
    });
  });

  group('server errors map to typed results', () {
    for (final (code, kind) in [
      (ErrorCode.pairingNotOpen, PairingFailureKind.pairingNotOpen),
      (ErrorCode.tooManyAttempts, PairingFailureKind.tooManyAttempts),
      (
        ErrorCode.pairingNotAllowedFromNetwork,
        PairingFailureKind.notAllowedFromNetwork,
      ),
      (ErrorCode.internal, PairingFailureKind.connectionLost),
    ]) {
      test('${code.wireName} → ${kind.name}', () async {
        final fake = pairingServer(onWrongCode: (_) => errorFor(code));
        final result = await pair(fake, code: '000000');
        expect(result, failedWith(kind));
        printOnFailure('$result');
        expect((result as PairingFailed).message, isNotEmpty);
      });
    }

    test('wrong code, retry on the same session, then the right one', () async {
      final fake = pairingServer();
      final session = await openSession(fake);
      expect(session.serverShortId, shortId(testServerFingerprint));
      expect(session.attemptsLeft, 3);

      final first = await session.submitCode('111111');
      expect(first, failedWith(PairingFailureKind.badCode));
      expect((first as PairingFailed).attemptsLeft, 2);
      expect(first.message, contains('2 more tries'));
      expect(session.isOpen, isTrue);

      final second = await session.submitCode('222222');
      expect((second as PairingFailed).attemptsLeft, 1);
      expect(second.message, contains('1 more try'));

      expect(await session.submitCode(goodCode), isA<PairingSucceeded>());
      expect(fake.calls, hasLength(1), reason: 'one connection');
    });

    test('3rd wrong code: server hangs up, 0 attempts left', () async {
      final fake = pairingServer();
      fake.answer = (server, host, request) {
        if (request is Hello) return unpairedHelloOk;
        hangUpLater(server);
        return errorFor(ErrorCode.badPairingCode);
      };
      final session = await openSession(fake);
      await session.submitCode('111111');
      await session.submitCode('222222');
      final third = await session.submitCode('333333');
      expect((third as PairingFailed).attemptsLeft, 0);
      await pumpEventQueue();
      expect(session.isOpen, isFalse);
      expect(
        await session.submitCode(goodCode),
        failedWith(PairingFailureKind.connectionLost),
      );
    });

    test('badCodeFormat on a session uses no attempt', () async {
      final session = await openSession(pairingServer());
      expect(
        await session.submitCode('12'),
        failedWith(PairingFailureKind.badCodeFormat),
      );
      expect(session.attemptsLeft, 3);
      await session.close();
    });
  });

  group('connection problems', () {
    test('nothing at the address: unreachable', () async {
      final fake = pairingServer()
        ..failureFor = (host) => const TlsConnectFailure(
          TlsConnectFailureKind.unreachable,
          'refused',
        );
      expect(await pair(fake), failedWith(PairingFailureKind.unreachable));
    });

    test('timeout: unreachable', () async {
      final fake = pairingServer()
        ..failureFor = (host) =>
            const TlsConnectFailure(TlsConnectFailureKind.timeout, 'slow');
      expect(await pair(fake), failedWith(PairingFailureKind.unreachable));
    });

    test('TLS handshake failed: tlsFailed', () async {
      final fake = pairingServer()
        ..failureFor = (host) => const TlsConnectFailure(
          TlsConnectFailureKind.handshakeFailed,
          'alert',
        );
      expect(await pair(fake), failedWith(PairingFailureKind.tlsFailed));
    });

    test('server hangs up before HelloOk: connectionLost', () async {
      final fake = pairingServer();
      fake.answer = (server, host, request) {
        hangUpLater(server);
        return null;
      };
      expect(await pair(fake), failedWith(PairingFailureKind.connectionLost));
    });

    test('server hangs up instead of answering PairRequest', () async {
      final fake = pairingServer();
      fake.answer = (server, host, request) {
        if (request is Hello) return unpairedHelloOk;
        hangUpLater(server);
        return null;
      };
      expect(await pair(fake), failedWith(PairingFailureKind.connectionLost));
    });

    test('wrong reply type to PairRequest: connectionLost', () async {
      final fake = pairingServer();
      fake.answer = (server, host, request) =>
          request is Hello ? unpairedHelloOk : const Pong();
      // Pong does not answer PairRequest: NasConnection closes the
      // connection, so this is reported as a lost connection.
      expect(await pair(fake), failedWith(PairingFailureKind.connectionLost));
    });
  });
}
