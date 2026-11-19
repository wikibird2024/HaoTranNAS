// A fake TLS connector: plays the pin check like TlsLink does (the pin
// sees [certificateFingerprint]) and hands out a FakeServer per connect.
// Used by the pairing and address book tests, so they run without
// sockets.
import 'dart:convert';
import 'dart:typed_data';

import 'package:haotrannas_mobile/core/transport/link.dart';
import 'package:haotrannas_mobile/core/transport/tls_link.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import 'fake_server.dart';

/// One call to [FakeTlsServer.connect].
typedef ConnectCall = ({
  String host,
  int port,
  ServerPin pin,
  ClientCertificate? clientCertificate,
  Duration timeout,
});

final testServerFingerprint = sha256Of(utf8.encode('test server cert'));

class FakeTlsServer {
  FakeTlsServer({Uint8List? certificateFingerprint})
    : certificateFingerprint = certificateFingerprint ?? testServerFingerprint;

  /// What the "server certificate" hashes to.
  Uint8List certificateFingerprint;

  final calls = <ConnectCall>[];
  final servers = <FakeServer>[];

  /// Thrown instead of connecting to [host] (TlsConnectFailure, ...);
  /// null = connect.
  Object? Function(String host)? failureFor;

  /// The reply of the server at [host]; null = stay silent. Default:
  /// [FakeServer.defaultAnswer].
  Message? Function(FakeServer server, String host, Message request) answer = (
    server,
    host,
    request,
  ) => FakeServer.defaultAnswer(request);

  /// Fingerprint the certificate at [host] hashes to; default
  /// [certificateFingerprint].
  Uint8List Function(String host)? fingerprintFor;

  FakeServer get lastServer => servers.last;

  Future<Link> connect(
    String host,
    int port, {
    required ServerPin pin,
    ClientCertificate? clientCertificate,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    calls.add((
      host: host,
      port: port,
      pin: pin,
      clientCertificate: clientCertificate,
      timeout: timeout,
    ));
    final failure = failureFor?.call(host);
    if (failure != null) throw failure;
    final fingerprint = fingerprintFor?.call(host) ?? certificateFingerprint;
    if (!pin.accepts(fingerprint)) {
      throw TlsPinMismatch(
        expected: pin.expectedFingerprint,
        seen: fingerprint,
      );
    }
    final server = FakeServer(link: FakeLink(description: 'fake tls $host'));
    server.answer = (request) => answer(server, host, request);
    servers.add(server);
    return server.link;
  }
}

/// Sends [message] after the current reply, unless the link is closed.
void sendLater(FakeServer server, Message message) {
  Future<void>.delayed(Duration.zero, () {
    if (!server.link.isClosed) server.send(message, 0);
  });
}

/// Closes the link after the current reply (the server hanging up).
void hangUpLater(FakeServer server) {
  Future<void>.delayed(Duration.zero, () {
    if (!server.link.isClosed) server.link.close();
  });
}
