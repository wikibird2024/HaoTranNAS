/// A `Link` over TLS 1.3 with certificate pinning and an optional client
/// certificate (mutual TLS), spec §1.
///
/// ```
///  TlsLink.connect(ip, port, pin, clientCertificate?)
///    SecurityContext(withTrustedRoots: false), TLS 1.3 minimum
///    + client cert/key as PEM (wrapped from DER)
///    TCP connect ─► TLS handshake
///      no trusted roots, so every server cert is "bad" ─► onBadCertificate:
///        true only when SHA-256(cert DER) matches the pin (TOFU: records it)
///    after the handshake: SHA-256(peerCertificate DER) == pin  (authoritative)
///      else destroy + TlsPinMismatch
/// ```
///
/// No hostname check: the client connects by IP and the pin alone decides
/// (spec §1, D-018); the failed hostname/IP check only routes the
/// certificate to `onBadCertificate`. dart:io does put the IP literal in
/// the SNI extension (RFC 6066 forbids that; seen in
/// `test/core/tls_link_test.dart`); rustls 0.23 servers ignore an IP SNI.
///
/// TLS 1.3 note (spec §6): the server checks the client certificate
/// after the client's side of the handshake is done, so a rejected client
/// certificate is not a connect error here: it shows up as an error or
/// end of [incoming] on the first read. `NasConnection` reports that as
/// `closedBeforeHello` ("maybe not paired").
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../protocol/limits.dart';
import '../bytes/hex.dart';
import 'link.dart';

/// A certificate and its private key, both DER, that this side shows the
/// server. `DeviceIdentity` (client/identity.dart) is one.
abstract interface class ClientCertificate {
  /// X.509 certificate, DER.
  Uint8List get certDer;

  /// Private key, PKCS#8 DER. Secret: never log it.
  Uint8List get keyPkcs8Der;
}

/// What server certificate to accept: a fixed SHA-256 fingerprint saved
/// at pairing, or trust on first use (pairing only), which accepts any
/// certificate and records its fingerprint.
sealed class ServerPin {
  const ServerPin();

  /// Yes when a certificate with [fingerprint] (SHA-256 of its DER) is
  /// the server. May be called more than once per connection.
  bool accepts(Uint8List fingerprint);

  /// The pinned fingerprint, or null for trust on first use.
  Uint8List? get expectedFingerprint;
}

/// Accepts only the certificate whose SHA-256 is [fingerprint].
final class FixedServerPin extends ServerPin {
  FixedServerPin(List<int> fingerprint)
    : fingerprint = Uint8List.fromList(fingerprint) {
    if (this.fingerprint.length != hashBytes) {
      throw ArgumentError.value(
        fingerprint.length,
        'fingerprint',
        'a SHA-256 fingerprint is $hashBytes bytes',
      );
    }
  }

  final Uint8List fingerprint;

  @override
  Uint8List get expectedFingerprint => fingerprint;

  @override
  bool accepts(Uint8List fingerprint) =>
      bytesEqual(fingerprint, this.fingerprint);

  @override
  String toString() => 'FixedServerPin(${toHex(fingerprint, separator: '')})';
}

/// Trust on first use (pairing, spec §7): accepts any server certificate
/// and records the fingerprint of the last one it saw. After a connect,
/// [seenFingerprint] is the server's certificate (the link checks it
/// once more after the handshake).
final class TrustOnFirstUsePin extends ServerPin {
  TrustOnFirstUsePin();

  /// SHA-256 of the server certificate, or null before a handshake.
  Uint8List? seenFingerprint;

  @override
  Uint8List? get expectedFingerprint => null;

  @override
  bool accepts(Uint8List fingerprint) {
    seenFingerprint = Uint8List.fromList(fingerprint);
    return true;
  }

  @override
  String toString() {
    final seen = seenFingerprint;
    return 'TrustOnFirstUsePin(${seen == null ? 'nothing seen' : toHex(seen, separator: '')})';
  }
}

/// The server showed a certificate whose fingerprint is not the pinned
/// one: another server at this address, or someone in the middle. The
/// connection was not used.
class TlsPinMismatch implements Exception {
  const TlsPinMismatch({required this.expected, required this.seen});

  final Uint8List? expected;
  final Uint8List seen;

  @override
  String toString() =>
      'TlsPinMismatch: expected server certificate '
      '${expected == null ? '(any)' : toHex(expected!, separator: '')}, '
      'server showed ${toHex(seen, separator: '')}';
}

enum TlsConnectFailureKind {
  /// Nothing answered at host:port (refused, unreachable, TCP timeout).
  unreachable,

  /// TCP connect + TLS handshake took longer than the timeout.
  timeout,

  /// The TLS handshake failed: not a TLS 1.3 server, an alert, or the
  /// server sent no certificate.
  handshakeFailed,

  /// The client certificate or key could not be loaded.
  badClientCertificate,
}

/// The link could not be opened (other than a pin mismatch).
class TlsConnectFailure implements Exception {
  const TlsConnectFailure(this.kind, this.message);

  final TlsConnectFailureKind kind;

  /// One line for a person.
  final String message;

  @override
  String toString() => 'TlsConnectFailure(${kind.name}): $message';
}

/// Opens a TLS link; [TlsLink.connect] is the real one, tests pass fakes.
typedef TlsConnector = Future<Link> Function(
  String host,
  int port, {
  required ServerPin pin,
  ClientCertificate? clientCertificate,
  Duration timeout,
});

class TlsLink implements Link {
  TlsLink._(this._socket, this.description, this.serverCertSha256)
    : incoming = _socket.asBroadcastStream();

  /// Connects to [host] (an IP address) and checks the server
  /// certificate against [pin]. With [clientCertificate] the phone proves
  /// it is a paired device (mutual TLS).
  ///
  /// [timeout] covers TCP connect and TLS handshake together.
  ///
  /// Throws [TlsPinMismatch] when the server certificate is not the
  /// pinned one, [TlsConnectFailure] for everything else.
  static Future<TlsLink> connect(
    String host,
    int port, {
    required ServerPin pin,
    ClientCertificate? clientCertificate,
    Duration timeout = const Duration(milliseconds: connectTimeoutMs),
  }) async {
    final context = _securityContext(clientCertificate);
    Uint8List? refusedFingerprint;
    bool onBadCertificate(X509Certificate certificate) {
      final fingerprint = sha256Of(certificate.der);
      if (pin.accepts(fingerprint)) return true;
      refusedFingerprint = fingerprint;
      return false;
    }

    final connecting = SecureSocket.connect(
      host,
      port,
      context: context,
      onBadCertificate: onBadCertificate,
      timeout: timeout,
    );
    final SecureSocket socket;
    try {
      // dart:io's own timeout covers only TCP connect, not the handshake.
      socket = await connecting.timeout(timeout);
    } on TimeoutException {
      // shortcut: a handshake that never ends keeps its socket until the
      // server gives up; it is destroyed as soon as it completes.
      connecting.then(
        (lateSocket) => lateSocket.destroy(),
        onError: (Object _) {},
      );
      throw TlsConnectFailure(
        TlsConnectFailureKind.timeout,
        'no TLS connection to $host:$port within ${timeout.inMilliseconds} ms',
      );
    } on SocketException catch (error) {
      throw TlsConnectFailure(
        TlsConnectFailureKind.unreachable,
        'cannot reach $host:$port: ${error.message}'
        '${error.osError == null ? '' : ' (${error.osError!.message})'}',
      );
    } on TlsException catch (error) {
      final seen = refusedFingerprint;
      if (seen != null) {
        throw TlsPinMismatch(expected: pin.expectedFingerprint, seen: seen);
      }
      throw TlsConnectFailure(
        TlsConnectFailureKind.handshakeFailed,
        'TLS handshake with $host:$port failed: ${_describeTlsError(error)}',
      );
    }

    // Authoritative check: onBadCertificate may have seen another
    // certificate of the chain, or not been called at all.
    final peerCertificate = socket.peerCertificate;
    if (peerCertificate == null) {
      socket.destroy();
      throw TlsConnectFailure(
        TlsConnectFailureKind.handshakeFailed,
        '$host:$port sent no server certificate',
      );
    }
    final fingerprint = sha256Of(peerCertificate.der);
    if (!pin.accepts(fingerprint)) {
      socket.destroy();
      throw TlsPinMismatch(
        expected: pin.expectedFingerprint,
        seen: fingerprint,
      );
    }
    // Small frames (Hello, Ping, ChunkOk) go out at once instead of
    // waiting for Nagle's algorithm to batch them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TlsLink._(socket, 'tls $host:$port', fingerprint);
  }

  static SecurityContext _securityContext(ClientCertificate? certificate) {
    // No public roots: the pin decides (spec §1).
    final context = SecurityContext(withTrustedRoots: false)
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    if (certificate == null) return context;
    try {
      context
        ..useCertificateChainBytes(
          utf8.encode(derToPem(certificate.certDer, pemCertificateLabel)),
        )
        ..usePrivateKeyBytes(
          utf8.encode(derToPem(certificate.keyPkcs8Der, pemPrivateKeyLabel)),
        );
    } on TlsException catch (error) {
      // The message comes from BoringSSL and never contains key bytes.
      throw TlsConnectFailure(
        TlsConnectFailureKind.badClientCertificate,
        'cannot load the device certificate or key: ${_describeTlsError(error)}',
      );
    } on ArgumentError catch (error) {
      // dart:io throws this for bytes that hold no PEM block of the kind.
      throw TlsConnectFailure(
        TlsConnectFailureKind.badClientCertificate,
        'cannot load the device certificate or key: ${error.message}',
      );
    }
    return context;
  }

  static String _describeTlsError(TlsException error) {
    final osMessage = error.osError?.message;
    return [
      error.message,
      if (osMessage != null && osMessage.isNotEmpty) osMessage,
    ].join(': ');
  }

  final SecureSocket _socket;

  @override
  final String description;

  /// SHA-256 of the server certificate this link checked.
  final Uint8List serverCertSha256;

  @override
  final Stream<Uint8List> incoming;

  Future<void> _sendQueue = Future.value();

  /// Sends run one after another: dart:io throws "StreamSink is bound to a
  /// stream" if a second add() comes while a flush() is still running.
  @override
  Future<void> send(Uint8List bytes) {
    final sent = _sendQueue.then((_) async {
      _socket.add(bytes);
      await _socket.flush();
    });
    _sendQueue = sent.catchError((Object _) {});
    return sent;
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } finally {
      _socket.destroy();
    }
  }
}

/// SHA-256 of [bytes], e.g. a certificate fingerprint.
Uint8List sha256Of(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

/// Same length and same bytes. Takes the same time wherever the first
/// difference is.
bool bytesEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index++) {
    difference |= first[index] ^ second[index];
  }
  return difference == 0;
}

const pemCertificateLabel = 'CERTIFICATE';

/// PKCS#8, unencrypted (spec §7 key format).
const pemPrivateKeyLabel = 'PRIVATE KEY';

/// Characters of base64 per PEM line (RFC 7468).
const pemLineCharacters = 64;

/// DER bytes → PEM text with [label]: `-----BEGIN <label>-----`, base64
/// in lines of 64, `-----END <label>-----`, each line ending in `\n`.
String derToPem(List<int> der, String label) {
  final base64Text = base64.encode(der);
  final buffer = StringBuffer('-----BEGIN $label-----\n');
  for (
    var offset = 0;
    offset < base64Text.length;
    offset += pemLineCharacters
  ) {
    final end = offset + pemLineCharacters < base64Text.length
        ? offset + pemLineCharacters
        : base64Text.length;
    buffer
      ..write(base64Text.substring(offset, end))
      ..write('\n');
  }
  buffer.write('-----END $label-----\n');
  return buffer.toString();
}
