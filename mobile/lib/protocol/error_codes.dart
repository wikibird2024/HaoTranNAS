/// The numbers carried by `Error.code` (spec §11) and `Close.reason`
/// (spec §12), with their names.
///
/// Messages keep the raw number: an unknown number from a newer server
/// is not a decode error, it is shown as `UNKNOWN(<n>)`.
library;

/// `Error.code` values, spec §11. Never reuse or renumber a code.
enum ErrorCode {
  malformedFrame(1, 'MALFORMED_FRAME', isFatal: true),
  versionMismatch(2, 'VERSION_MISMATCH', isFatal: true),
  unexpectedMessage(3, 'UNEXPECTED_MESSAGE', isFatal: true),
  notPaired(4, 'NOT_PAIRED', isFatal: true),
  pairingNotOpen(5, 'PAIRING_NOT_OPEN', isFatal: false),

  /// Not fatal by itself; the server makes the 3rd failure on one
  /// connection fatal (`maxPairFailuresPerConnection`).
  badPairingCode(6, 'BAD_PAIRING_CODE', isFatal: false),
  tooManyAttempts(7, 'TOO_MANY_ATTEMPTS', isFatal: true),
  pairingNotAllowedFromNetwork(
    8,
    'PAIRING_NOT_ALLOWED_FROM_NETWORK',
    isFatal: true,
  ),
  badPath(20, 'BAD_PATH', isFatal: false),
  badArgument(21, 'BAD_ARGUMENT', isFatal: false),
  tooLarge(22, 'TOO_LARGE', isFatal: false),
  chunkHashMismatch(23, 'CHUNK_HASH_MISMATCH', isFatal: false),
  chunkSizeWrong(24, 'CHUNK_SIZE_WRONG', isFatal: false),
  unknownUpload(25, 'UNKNOWN_UPLOAD', isFatal: false),
  chunksMissing(26, 'CHUNKS_MISSING', isFatal: false),
  fileHashMismatch(27, 'FILE_HASH_MISMATCH', isFatal: false),
  diskFull(28, 'DISK_FULL', isFatal: false),
  notFound(40, 'NOT_FOUND', isFatal: false),
  internal(50, 'INTERNAL', isFatal: false),
  shuttingDown(51, 'SHUTTING_DOWN', isFatal: true);

  const ErrorCode(this.number, this.wireName, {required this.isFatal});

  /// The u16 sent on the wire.
  final int number;

  /// The spec's name, e.g. `NOT_FOUND`.
  final String wireName;

  /// The server closes the connection right after sending this error.
  final bool isFatal;

  static final Map<int, ErrorCode> _byNumber = {
    for (final code in values) code.number: code,
  };

  /// The known code for [number], or null for a number this app does not
  /// know (not an error: see [errorCodeName]).
  static ErrorCode? fromNumber(int number) => _byNumber[number];
}

/// `NOT_FOUND` for 40, `UNKNOWN(999)` for a number this app does not know.
String errorCodeName(int number) =>
    ErrorCode.fromNumber(number)?.wireName ?? 'UNKNOWN($number)';

/// `Close.reason` values, spec §12.
enum CloseReason {
  normal(0, 'NORMAL'),
  handshakeTimeout(1, 'HANDSHAKE_TIMEOUT'),
  idleTimeout(2, 'IDLE_TIMEOUT'),
  protocolError(3, 'PROTOCOL_ERROR'),
  serverShutdown(4, 'SERVER_SHUTDOWN'),
  pairedReconnect(5, 'PAIRED_RECONNECT');

  const CloseReason(this.number, this.wireName);

  /// The u16 sent on the wire.
  final int number;

  /// The spec's name, e.g. `IDLE_TIMEOUT`.
  final String wireName;

  static final Map<int, CloseReason> _byNumber = {
    for (final reason in values) reason.number: reason,
  };

  /// The known reason for [number], or null for an unknown one.
  static CloseReason? fromNumber(int number) => _byNumber[number];
}

/// `IDLE_TIMEOUT` for 2, `UNKNOWN(9)` for a number this app does not know.
String closeReasonName(int number) =>
    CloseReason.fromNumber(number)?.wireName ?? 'UNKNOWN($number)';
