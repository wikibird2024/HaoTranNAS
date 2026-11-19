// TlsLink: PEM wrapping and pin logic (pure), then real TLS 1.3 over
// loopback against a dart:io SecureServerSocket with openssl-made
// certificates. That second part proves what dart:io (BoringSSL) does on
// this PC; it is skipped when `openssl` is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/core/transport/tls_link.dart';
import 'package:haotrannas_client/testing/tls_test_certificates.dart';

class _Certificate implements ClientCertificate {
  _Certificate(this.certDer, this.keyPkcs8Der);

  @override
  final Uint8List certDer;

  @override
  final Uint8List keyPkcs8Der;
}

Matcher failsWithKind(TlsConnectFailureKind kind) => throwsA(
  isA<TlsConnectFailure>().having((failure) => failure.kind, 'kind', kind),
);

/// A TLS 1.3 echo server on 127.0.0.1 with the test server certificate.
/// It asks for a client certificate and trusts only the device CA.
class _EchoServer {
  _EchoServer._(this.socket);

  final SecureServerSocket socket;

  /// The client certificate of each connection (null = none sent).
  final clientCertificates = <X509Certificate?>[];

  /// Errors of failed server-side handshakes.
  final handshakeErrors = <Object>[];

  int get port => socket.port;

  static Future<_EchoServer> start(
    TlsTestCertificates certificates, {
    bool isClientCertificateRequired = false,
  }) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificates.server.pem))
      ..usePrivateKeyBytes(utf8.encode(certificates.serverKeyPem))
      ..setTrustedCertificatesBytes(utf8.encode(certificates.deviceCa.pem))
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    final socket = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: isClientCertificateRequired,
    );
    final server = _EchoServer._(socket);
    socket.listen(
      (client) {
        server.clientCertificates.add(client.peerCertificate);
        client.listen(client.add, onError: (Object _) {}, onDone: client.close);
      },
      // A failed handshake arrives here; the server keeps listening.
      onError: server.handshakeErrors.add,
    );
    return server;
  }

  Future<void> close() => socket.close();
}

/// Sends [text] over [link] and waits for the same bytes back.
Future<String> echo(TlsLink link, String text) async {
  final received = <int>[];
  final gotAll = Completer<void>();
  final subscription = link.incoming.listen((bytes) {
    received.addAll(bytes);
    if (received.length >= text.length && !gotAll.isCompleted) {
      gotAll.complete();
    }
  });
  await link.send(Uint8List.fromList(utf8.encode(text)));
  await gotAll.future.timeout(const Duration(seconds: 5));
  await subscription.cancel();
  return utf8.decode(received);
}

void main() {
  group('derToPem', () {
    test('64-character base64 lines between BEGIN and END', () {
      final der = Uint8List.fromList(List.generate(100, (index) => index));
      final pem = derToPem(der, 'CERTIFICATE');
      final lines = pem.split('\n');
      expect(lines.first, '-----BEGIN CERTIFICATE-----');
      // 100 bytes = 136 base64 characters = 64 + 64 + 8.
      expect(
        [for (final line in lines.sublist(1, 4)) line.length],
        [64, 64, 8],
      );
      expect(lines[4], '-----END CERTIFICATE-----');
      expect(lines[5], '', reason: 'ends with a newline');
      expect(base64.decode(lines.sublist(1, 4).join()), der);
    });

    test('exact multiple of 64 has no empty line; empty DER has none', () {
      // 48 bytes = 64 base64 characters.
      final pem = derToPem(Uint8List(48), 'PRIVATE KEY');
      expect(
        pem,
        '-----BEGIN PRIVATE KEY-----\n${'A' * 64}\n-----END PRIVATE KEY-----\n',
      );
      expect(
        derToPem(Uint8List(0), 'X'),
        '-----BEGIN X-----\n-----END X-----\n',
      );
    });
  });

  group('ServerPin', () {
    final fingerprint = sha256Of(utf8.encode('server certificate'));
    final otherFingerprint = sha256Of(utf8.encode('another certificate'));

    test('fixed pin accepts only its fingerprint', () {
      final pin = FixedServerPin(fingerprint);
      expect(pin.accepts(fingerprint), isTrue);
      expect(pin.accepts(otherFingerprint), isFalse);
      expect(pin.accepts(fingerprint.sublist(0, 31)), isFalse);
      expect(pin.expectedFingerprint, fingerprint);
    });

    test('fixed pin must be 32 bytes', () {
      expect(() => FixedServerPin(Uint8List(16)), throwsArgumentError);
    });

    test('trust on first use accepts anything and records the last', () {
      final pin = TrustOnFirstUsePin();
      expect(pin.seenFingerprint, isNull);
      expect(pin.expectedFingerprint, isNull);
      expect(pin.accepts(otherFingerprint), isTrue);
      expect(pin.accepts(fingerprint), isTrue);
      expect(pin.seenFingerprint, fingerprint);
    });

    test('bytesEqual', () {
      expect(bytesEqual([1, 2, 3], [1, 2, 3]), isTrue);
      expect(bytesEqual([1, 2, 3], [1, 2, 4]), isFalse);
      expect(bytesEqual([1, 2], [1, 2, 3]), isFalse);
      expect(bytesEqual([], []), isTrue);
    });

    test('TlsPinMismatch names both fingerprints', () {
      final text = TlsPinMismatch(
        expected: fingerprint,
        seen: otherFingerprint,
      ).toString();
      expect(text, contains(fingerprint.first.toRadixString(16)));
      expect(text, contains('server showed'));
    });
  });

  group(
    'real TLS 1.3 over loopback (openssl certificates)',
    skip: TlsTestCertificates.skipReason,
    () {
      late TlsTestCertificates certificates;
      late Uint8List serverFingerprint;
      late _EchoServer server;

      setUpAll(() async {
        certificates = await TlsTestCertificates.create();
        serverFingerprint = sha256Of(certificates.server.der);
      });

      tearDownAll(() => certificates.delete());

      setUp(() async => server = await _EchoServer.start(certificates));

      tearDown(() => server.close());

      test('derToPem matches what openssl wrote', () {
        expect(
          derToPem(certificates.server.der, pemCertificateLabel),
          certificates.server.pem,
        );
      });

      test('right pin: connects, echoes, no client certificate sent', () async {
        final link = await TlsLink.connect(
          '127.0.0.1',
          server.port,
          pin: FixedServerPin(serverFingerprint),
        );
        expect(link.description, 'tls 127.0.0.1:${server.port}');
        expect(link.serverCertSha256, serverFingerprint);
        expect(await echo(link, 'hello over TLS'), 'hello over TLS');
        expect(server.clientCertificates, [null]);
        await link.close();
      });

      test('wrong pin: TlsPinMismatch with what the server showed', () async {
        final wrongFingerprint = sha256Of(utf8.encode('not the server'));
        await expectLater(
          TlsLink.connect(
            '127.0.0.1',
            server.port,
            pin: FixedServerPin(wrongFingerprint),
          ),
          throwsA(
            isA<TlsPinMismatch>()
                .having((error) => error.seen, 'seen', serverFingerprint)
                .having(
                  (error) => error.expected,
                  'expected',
                  wrongFingerprint,
                ),
          ),
        );
      });

      test('trust on first use records the server fingerprint', () async {
        final pin = TrustOnFirstUsePin();
        final link = await TlsLink.connect('127.0.0.1', server.port, pin: pin);
        expect(pin.seenFingerprint, serverFingerprint);
        expect(link.serverCertSha256, serverFingerprint);
        await link.close();
      });

      test(
        'client certificate (PKCS#8 DER → PEM) reaches the server',
        () async {
          final link = await TlsLink.connect(
            '127.0.0.1',
            server.port,
            pin: FixedServerPin(serverFingerprint),
            clientCertificate: _Certificate(
              certificates.device.der,
              certificates.deviceKeyPkcs8Der,
            ),
          );
          expect(await echo(link, 'mutual'), 'mutual');
          expect(
            server.clientCertificates.single?.der,
            certificates.device.der,
          );
          await link.close();
        },
      );

      test('client certificate the server rejects: connect succeeds, '
          'first read fails (spec §6 TLS 1.3 note)', () async {
        final strictServer = await _EchoServer.start(
          certificates,
          isClientCertificateRequired: true,
        );
        addTearDown(strictServer.close);
        final link = await TlsLink.connect(
          '127.0.0.1',
          strictServer.port,
          pin: FixedServerPin(serverFingerprint),
          clientCertificate: _Certificate(
            certificates.strangerDevice.der,
            certificates.strangerDeviceKeyPkcs8Der,
          ),
        );
        final ended = Completer<String>();
        link.incoming.listen(
          (bytes) {},
          onError: (Object error) {
            if (!ended.isCompleted) ended.complete('error: $error');
          },
          onDone: () {
            if (!ended.isCompleted) ended.complete('done');
          },
        );
        await link.send(Uint8List.fromList(utf8.encode('hello')));
        final how = await ended.future.timeout(const Duration(seconds: 5));
        printOnFailure('first read ended with: $how');
        expect(strictServer.clientCertificates, isEmpty);
        expect(strictServer.handshakeErrors, isNotEmpty);
        await link.close();
      });

      test('bad client key bytes: badClientCertificate', () async {
        await expectLater(
          TlsLink.connect(
            '127.0.0.1',
            server.port,
            pin: FixedServerPin(serverFingerprint),
            clientCertificate: _Certificate(
              certificates.device.der,
              Uint8List.fromList([1, 2, 3]),
            ),
          ),
          failsWithKind(TlsConnectFailureKind.badClientCertificate),
        );
      });

      // RFC 6066 forbids an IP literal as SNI, but dart:io sends it.
      // rustls 0.23 ignores an IP SNI (server/hs.rs, with a warning), so
      // this is harmless; the test notices if dart:io ever changes.
      test('dart:io sends the IP as SNI (rustls ignores it)', () async {
        // A plain TCP server that keeps the ClientHello bytes.
        final plainServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(plainServer.close);
        final clientHello = Completer<List<int>>();
        plainServer.listen((client) {
          client.listen((bytes) {
            if (!clientHello.isCompleted) clientHello.complete(bytes);
            client.destroy();
          });
        });
        final connecting = TlsLink.connect(
          '127.0.0.1',
          plainServer.port,
          pin: TrustOnFirstUsePin(),
        );
        final helloBytes = await clientHello.future;
        await expectLater(
          connecting,
          failsWithKind(TlsConnectFailureKind.handshakeFailed),
        );
        expect(latin1.decode(helloBytes), contains('127.0.0.1'));
      });
    },
  );

  group('connect failures without a TLS server', () {
    test('nobody listening: unreachable', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
        TlsLink.connect('127.0.0.1', port, pin: TrustOnFirstUsePin()),
        failsWithKind(TlsConnectFailureKind.unreachable),
      );
    });

    test('server accepts TCP but never answers TLS: timeout', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clients = <Socket>[];
      silent.listen(clients.add);
      addTearDown(() async {
        for (final client in clients) {
          client.destroy();
        }
        await silent.close();
      });
      final stopwatch = Stopwatch()..start();
      await expectLater(
        TlsLink.connect(
          '127.0.0.1',
          silent.port,
          pin: TrustOnFirstUsePin(),
          timeout: const Duration(milliseconds: 300),
        ),
        failsWithKind(TlsConnectFailureKind.timeout),
      );
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });

    test('plain-text server: handshakeFailed', () async {
      final plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(plain.close);
      plain.listen((client) {
        client.add(utf8.encode('HTTP/1.0 400 not TLS\r\n\r\n'));
        client.close();
      });
      await expectLater(
        TlsLink.connect('127.0.0.1', plain.port, pin: TrustOnFirstUsePin()),
        failsWithKind(TlsConnectFailureKind.handshakeFailed),
      );
    });
  });
}
