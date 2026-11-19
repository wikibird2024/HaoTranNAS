/// One-time pairing on the LAN (spec §7): the user types the 6-digit code
/// that `haotrannas-server pair` printed; the server answers with this
/// phone's certificate and key.
///
/// ```
///  PairingSession.open(ip, port)
///    TlsLink, trust on first use, no client cert ─► fingerprint seen
///    Hello ─► HelloOk(device 0)                    ─► serverShortId to show
///  submitCode("482913", expectedShortId?)
///    short id typed? must match the one seen (before the code is sent)
///    PairRequest ─► PairOk
///      PairOk.server_cert_sha256 == fingerprint seen? else stop (MITM)
///    server sends Close(PAIRED_RECONNECT) ─► normal end
///  ─► PairingSucceeded(identity, serverShortId): save it, reconnect with it
/// ```
///
/// Known weakness (spec §7): the code does not prove the server. The user
/// comparing [PairingSucceeded.serverShortId] with the server's printout
/// is the defence in v1.
library;

import 'dart:async';
import 'dart:typed_data';

import '../core/log/session_log.dart';
import '../core/transport/tls_link.dart';
import '../protocol/error_codes.dart';
import '../protocol/limits.dart';
import '../protocol/messages.dart';
import 'identity.dart';
import 'nas_connection.dart';

/// How long to wait for the server's Close(PAIRED_RECONNECT) after PairOk
/// before closing from this side. Either way pairing worked.
const int pairedCloseWaitMs = 2000;

enum PairingFailureKind {
  /// The code is not 6 digits; nothing was sent, no attempt used.
  badCodeFormat,

  /// BAD_PAIRING_CODE: wrong code.
  badCode,

  /// PAIRING_NOT_OPEN: no `pair` running on the server.
  pairingNotOpen,

  /// TOO_MANY_ATTEMPTS: the server locked this pairing window.
  tooManyAttempts,

  /// PAIRING_NOT_ALLOWED_FROM_NETWORK: not on the home LAN.
  notAllowedFromNetwork,

  /// PairOk names another server certificate than the one TLS showed.
  serverMismatch,

  /// The server's short id is not the one the user typed.
  shortIdMismatch,

  /// Nothing answered at the address, or not in time.
  unreachable,

  /// TLS handshake failed (not a HaoTranNAS server, or not TLS 1.3).
  tlsFailed,

  /// The connection ended (or another server error) before PairOk.
  connectionLost,

  /// The server answered something that does not fit the protocol.
  badReply,
}

sealed class PairingResult {
  const PairingResult();
}

/// Paired. Save [identity] (`IdentityStore.save`) and show
/// [serverShortId] so the user can compare it with the server's.
final class PairingSucceeded extends PairingResult {
  const PairingSucceeded({required this.identity, required this.serverShortId});

  final DeviceIdentity identity;
  final String serverShortId;

  @override
  String toString() => 'PairingSucceeded($identity)';
}

/// Not paired; nothing to save. [message] is for the user.
final class PairingFailed extends PairingResult implements Exception {
  const PairingFailed(this.kind, this.message, {this.attemptsLeft});

  final PairingFailureKind kind;

  /// One or two plain sentences for the user.
  final String message;

  /// For [PairingFailureKind.badCode]: codes the server still takes on
  /// this connection (`maxPairFailuresPerConnection` minus failures).
  final int? attemptsLeft;

  @override
  String toString() => 'PairingFailed(${kind.name}): $message';
}

/// An open, unpaired connection to a server, ready for codes.
class PairingSession {
  PairingSession._(this._connection, this.serverFingerprint, this._address);

  /// Connects with TLS (trust on first use, no client certificate) and
  /// says Hello. Throws [PairingFailed] when that does not work.
  ///
  /// [connect] is [TlsLink.connect]; tests pass a fake.
  static Future<PairingSession> open({
    required String host,
    required int port,
    required String deviceName,
    required String clientSoftware,
    TlsConnector connect = TlsLink.connect,
    Duration connectTimeout = const Duration(milliseconds: connectTimeoutMs),
    SessionLog? log,
  }) async {
    final address = '$host:$port';
    final pin = TrustOnFirstUsePin();
    final NasConnection connection;
    try {
      final link = await connect(host, port, pin: pin, timeout: connectTimeout);
      connection = await NasConnection.open(
        link,
        clientSoftware: clientSoftware,
        deviceName: deviceName,
        log: log,
      );
    } on TlsConnectFailure catch (failure) {
      throw switch (failure.kind) {
        TlsConnectFailureKind.unreachable ||
        TlsConnectFailureKind.timeout => PairingFailed(
          PairingFailureKind.unreachable,
          'No server answered at $address. Check the address and that '
          'the phone is on the home Wi-Fi.',
        ),
        _ => PairingFailed(
          PairingFailureKind.tlsFailed,
          'Could not open a secure connection to $address: '
          '${failure.message}',
        ),
      };
    } on NasFailure catch (failure) {
      throw PairingFailed(
        PairingFailureKind.connectionLost,
        'The server at $address closed the connection: ${failure.message}',
      );
    }
    final fingerprint = pin.seenFingerprint;
    if (fingerprint == null || connection.helloOk.deviceId != 0) {
      await connection.close();
      throw PairingFailed(
        PairingFailureKind.badReply,
        fingerprint == null
            ? 'The server at $address showed no certificate.'
            : 'The server at $address says this phone is already device '
                  '${connection.helloOk.deviceId} without a certificate.',
      );
    }
    return PairingSession._(connection, fingerprint, address);
  }

  final NasConnection _connection;
  final String _address;
  int _failures = 0;

  /// SHA-256 of the certificate the server showed (trust on first use).
  final Uint8List serverFingerprint;

  /// Show it while the user types the code: it must match the server's.
  String get serverShortId => shortId(serverFingerprint);

  /// Codes the server still takes on this connection.
  int get attemptsLeft => _failures >= maxPairFailuresPerConnection
      ? 0
      : maxPairFailuresPerConnection - _failures;

  /// The connection is still there for another code.
  bool get isOpen => _connection.isReady;

  /// Sends [code] and returns the result; never throws for user, server
  /// or network problems. After [PairingFailureKind.badCode] or
  /// [PairingFailureKind.badCodeFormat] the session may take another code
  /// while [isOpen]; after anything else it is closed.
  ///
  /// With [expectedShortId] (typed by the user from the server's
  /// printout) the code is sent only if the server's short id matches.
  Future<PairingResult> submitCode(
    String code, {
    String? expectedShortId,
  }) async {
    final formatProblem = _codeFormatProblem(code);
    if (formatProblem != null) return formatProblem;
    if (expectedShortId != null &&
        !shortIdMatches(expectedShortId, serverFingerprint)) {
      await close();
      return PairingFailed(
        PairingFailureKind.shortIdMismatch,
        'This server\'s id is $serverShortId, not $expectedShortId. It may '
        'be another device; pairing stopped and the code was not sent.',
      );
    }
    if (!isOpen) {
      return const PairingFailed(
        PairingFailureKind.connectionLost,
        'The connection to the server is closed. Start pairing again.',
      );
    }
    final Message reply;
    try {
      reply = await _connection.request(PairRequest(code: code));
    } on NasRequestError catch (error) {
      return _failedByServer(error);
    } on NasFailure catch (failure) {
      await close();
      return PairingFailed(
        PairingFailureKind.connectionLost,
        'The connection ended before the server answered: '
        '${failure.message}',
      );
    }
    if (reply is! PairOk) {
      await close();
      return PairingFailed(
        PairingFailureKind.badReply,
        'The server answered ${reply.messageName} instead of PairOk.',
      );
    }
    if (!bytesEqual(reply.serverCertSha256, serverFingerprint)) {
      await close();
      return const PairingFailed(
        PairingFailureKind.serverMismatch,
        'The server\'s answer names another certificate than the one it '
        'showed. Someone may be in the middle; nothing was saved.',
      );
    }
    final DeviceIdentity identity;
    try {
      identity = DeviceIdentity(
        deviceId: reply.deviceId,
        certDer: reply.deviceCertDer,
        keyPkcs8Der: reply.deviceKeyPkcs8Der,
        serverCertSha256: serverFingerprint,
      );
    } on ArgumentError {
      await close();
      return const PairingFailed(
        PairingFailureKind.badReply,
        'The server sent an unusable device certificate.',
      );
    }
    await _waitForServerClose();
    return PairingSucceeded(identity: identity, serverShortId: serverShortId);
  }

  /// Closes the connection. Safe to call more than once.
  Future<void> close() => _connection.close();

  PairingResult _failedByServer(NasRequestError error) {
    switch (error.knownCode) {
      case ErrorCode.badPairingCode:
        _failures++;
        final attempts = isOpen ? attemptsLeft : 0;
        return PairingFailed(
          PairingFailureKind.badCode,
          attempts > 0
              ? 'Wrong code. Check the $pairingCodeDigits digits on the '
                    'server; $attempts more ${attempts == 1 ? 'try' : 'tries'} '
                    'on this connection.'
              : 'Wrong code. The server closed this connection; connect '
                    'again and type the code the server shows.',
          attemptsLeft: attempts,
        );
      case ErrorCode.pairingNotOpen:
        return const PairingFailed(
          PairingFailureKind.pairingNotOpen,
          'The server is not waiting for a phone. Run '
          '`haotrannas-server pair` on it and type the new code within 2 '
          'minutes.',
        );
      case ErrorCode.tooManyAttempts:
        return const PairingFailed(
          PairingFailureKind.tooManyAttempts,
          'Too many wrong codes: the server stopped this pairing. Start a '
          'new pairing on the server.',
        );
      case ErrorCode.pairingNotAllowedFromNetwork:
        return const PairingFailed(
          PairingFailureKind.notAllowedFromNetwork,
          'The server pairs phones only on the home network. Join the home '
          'Wi-Fi (not WireGuard or mobile data) and try again.',
        );
      default:
        return PairingFailed(
          PairingFailureKind.connectionLost,
          'The server at $_address refused pairing: '
          '${error.codeName} ${error.message}',
        );
    }
  }

  /// The server ends the connection with Close(PAIRED_RECONNECT); any
  /// end is fine. Closes from this side after [pairedCloseWaitMs].
  Future<void> _waitForServerClose() async {
    final closed = Completer<void>();
    void onState() {
      if (_connection.state.value is NasClosed && !closed.isCompleted) {
        closed.complete();
      }
    }

    _connection.state.addListener(onState);
    onState();
    try {
      await closed.future.timeout(
        const Duration(milliseconds: pairedCloseWaitMs),
        onTimeout: () {},
      );
    } finally {
      _connection.state.removeListener(onState);
      await close();
    }
  }
}

/// Null when [code] is 6 ASCII digits (spec §7).
PairingFailed? _codeFormatProblem(String code) =>
    RegExp('^[0-9]{$pairingCodeDigits}\$').hasMatch(code)
    ? null
    : const PairingFailed(
        PairingFailureKind.badCodeFormat,
        'The code is $pairingCodeDigits digits, like 482913.',
      );

/// Pairs in one call: [PairingSession.open], one [code], close. Never
/// throws for user, server or network problems.
Future<PairingResult> pairWithServer({
  required String host,
  required int port,
  required String code,
  required String deviceName,
  required String clientSoftware,
  String? expectedShortId,
  TlsConnector connect = TlsLink.connect,
  Duration connectTimeout = const Duration(milliseconds: connectTimeoutMs),
  SessionLog? log,
}) async {
  // Checked here too, so a typo does not cost a connection.
  final formatProblem = _codeFormatProblem(code);
  if (formatProblem != null) return formatProblem;
  final PairingSession session;
  try {
    session = await PairingSession.open(
      host: host,
      port: port,
      deviceName: deviceName,
      clientSoftware: clientSoftware,
      connect: connect,
      connectTimeout: connectTimeout,
      log: log,
    );
  } on PairingFailed catch (failed) {
    return failed;
  }
  try {
    return await session.submitCode(code, expectedShortId: expectedShortId);
  } finally {
    await session.close();
  }
}
