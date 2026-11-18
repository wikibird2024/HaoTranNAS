/// One session with the server over a `Link` (spec §3, §6): Hello →
/// HelloOk, request/reply matching by requestId, one request at a time,
/// Ping after `pingIntervalMs` without traffic, timeouts and a clean
/// Close. Logs every frame to the `SessionLog`.
///
/// ```
///  request() ─► queue ─► in flight (1) ─► encodeFrame ─► Link.send
///                             ▲
///  Link.incoming ─► FrameAssembler ─► decodeMessage ─► match requestId
/// ```
///
/// Never throws on bad bytes from the network: a bad frame, an unknown
/// request id, a server Close or the link ending closes the connection
/// and fails every waiting request with a [NasFailure].
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/log/session_log.dart';
import '../core/transport/link.dart';
import '../protocol/codec.dart';
import '../protocol/error_codes.dart';
import '../protocol/frame_assembler.dart';
import '../protocol/limits.dart';
import '../protocol/messages.dart';

/// Largest request id; the next one after it is 1 (0 is never used).
const int maxRequestId = 0xFFFFFFFF;

/// Bytes of one frame kept in the [SessionLog]. A ChunkData frame is
/// 1 MiB; keeping whole frames would fill the phone's memory.
const int maxLoggedFrameBytes = 1024;

/// Why a connection ended.
enum NasFailureKind {
  /// The link ended before HelloOk. Over TLS 1.3 a rejected client
  /// certificate looks like this (spec §6): treat it as "maybe not
  /// paired".
  closedBeforeHello,

  /// No HelloOk within `handshakeTimeoutMs`.
  handshakeTimeout,

  /// The server refused our version (Error VERSION_MISMATCH) or answered
  /// with another one.
  versionMismatch,

  /// A fatal Error from the server, or an Error during the handshake.
  /// See [NasFailure.errorCode].
  serverError,

  /// The server sent Close. See [NasFailure.closeReason].
  serverClosed,

  /// The link ended or failed after HelloOk.
  linkClosed,

  /// The server sent bytes that are not a valid frame (MALFORMED_FRAME).
  malformed,

  /// A reply with an unknown request id or the wrong type.
  unexpectedReply,

  /// A request got no reply within the request timeout.
  requestTimeout,

  /// This app called `close()`.
  closedByClient,
}

/// The connection is gone. Every waiting request fails with this.
class NasFailure implements Exception {
  const NasFailure(this.kind, this.message, {this.closeReason, this.errorCode});

  final NasFailureKind kind;

  /// One line for a person.
  final String message;

  /// The raw `Close.reason` for [NasFailureKind.serverClosed].
  final int? closeReason;

  /// The raw `Error.code` for [NasFailureKind.serverError] and an Error
  /// VERSION_MISMATCH.
  final int? errorCode;

  /// The link ended before HelloOk, or the server said NOT_PAIRED: the
  /// phone should offer to pair (again).
  bool get isMaybeNotPaired =>
      kind == NasFailureKind.closedBeforeHello ||
      errorCode == ErrorCode.notPaired.number;

  @override
  String toString() => 'NasFailure(${kind.name}): $message';
}

/// The server answered one request with Error (spec §11). The connection
/// stays open unless [isFatal].
class NasRequestError implements Exception {
  const NasRequestError(this.code, this.message, {required this.isFatal});

  factory NasRequestError.fromMessage(ErrorMessage error) => NasRequestError(
    error.code,
    error.message,
    isFatal: error.knownCode?.isFatal ?? false,
  );

  /// Raw `Error.code`; may be a number this app does not know.
  final int code;
  final String message;

  /// The server closes the connection after this error.
  final bool isFatal;

  ErrorCode? get knownCode => ErrorCode.fromNumber(code);

  /// `NOT_FOUND`, or `UNKNOWN(<n>)`.
  String get codeName => errorCodeName(code);

  @override
  String toString() => 'NasRequestError($codeName): $message';
}

/// What the UI shows: connecting → ready → closed.
sealed class NasConnectionState {
  const NasConnectionState();
}

final class NasConnecting extends NasConnectionState {
  const NasConnecting();

  @override
  String toString() => 'connecting';
}

final class NasReady extends NasConnectionState {
  const NasReady(this.helloOk);

  final HelloOk helloOk;

  @override
  String toString() => 'ready (${helloOk.serverName})';
}

final class NasClosed extends NasConnectionState {
  const NasClosed(this.cause);

  /// Why; kind [NasFailureKind.closedByClient] after `close()`.
  final NasFailure cause;

  @override
  String toString() => 'closed: ${cause.message}';
}

final class _PendingRequest {
  _PendingRequest(this.message);

  final Message message;
  final completer = Completer<Message>();
  int requestId = 0;
  Timer? timeoutTimer;
}

class NasConnection {
  /// A connection in [NasConnecting]; call [start] to send Hello. Most
  /// callers use [open]. Requests made before HelloOk wait in the queue.
  NasConnection(
    this._link, {
    required this.clientSoftware,
    required this.deviceName,
    this.log,
    this.requestTimeout = const Duration(seconds: 30),
    this.pingInterval = const Duration(milliseconds: pingIntervalMs),
    this.handshakeTimeout = const Duration(milliseconds: handshakeTimeoutMs),
  });

  /// Sends Hello and waits for HelloOk. Throws [NasFailure] (link
  /// closed) if the handshake fails, or [ArgumentError] if
  /// [clientSoftware] or [deviceName] is over `maxNameBytes`.
  static Future<NasConnection> open(
    Link link, {
    required String clientSoftware,
    required String deviceName,
    SessionLog? log,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration pingInterval = const Duration(milliseconds: pingIntervalMs),
    Duration handshakeTimeout = const Duration(
      milliseconds: handshakeTimeoutMs,
    ),
  }) async {
    final connection = NasConnection(
      link,
      clientSoftware: clientSoftware,
      deviceName: deviceName,
      log: log,
      requestTimeout: requestTimeout,
      pingInterval: pingInterval,
      handshakeTimeout: handshakeTimeout,
    );
    await connection.start();
    return connection;
  }

  final Link _link;

  /// Where every frame and state change is written; null = no log.
  final SessionLog? log;
  final String clientSoftware;
  final String deviceName;
  final Duration requestTimeout;
  final Duration pingInterval;
  final Duration handshakeTimeout;

  final _assembler = FrameAssembler();
  final _waiting = Queue<_PendingRequest>();
  final _state = ValueNotifier<NasConnectionState>(const NasConnecting());
  StreamSubscription<Uint8List>? _subscription;
  _PendingRequest? _inFlight;
  HelloOk? _helloOk;
  NasFailure? _closedBy;
  Timer? _pingTimer;
  Future<HelloOk>? _started;
  Future<void>? _linkClosed;
  int _nextRequestId = 1;

  /// Connecting, ready or closed; listen to it from the UI.
  ValueListenable<NasConnectionState> get state => _state;

  /// The server's HelloOk. Throws [StateError] before the handshake.
  HelloOk get helloOk =>
      _helloOk ?? (throw StateError('handshake not finished'));

  bool get isReady => _helloOk != null && _closedBy == null;

  /// Why the connection ended, or null while it is open.
  NasFailure? get closedBy => _closedBy;

  /// Starts the next request ids at [requestId]: tests use it to check
  /// the wrap from [maxRequestId] to 1.
  @visibleForTesting
  set nextRequestIdForTest(int requestId) => _nextRequestId = requestId;

  /// Sends Hello and completes with HelloOk. Calling it again returns the
  /// same future.
  Future<HelloOk> start() => _started ??= _handshake();

  Future<HelloOk> _handshake() async {
    final failure = _closedBy;
    if (failure != null) throw failure;
    log?.note('connecting over ${_link.description}');
    _subscription = _link.incoming.listen(
      _onBytes,
      onError: _onLinkError,
      onDone: _onLinkDone,
      cancelOnError: true,
    );
    final hello = _PendingRequest(
      Hello(
        protocolVersion: protocolVersion,
        clientSoftware: clientSoftware,
        deviceName: deviceName,
      ),
    );
    try {
      _send(hello, handshakeTimeout, NasFailureKind.handshakeTimeout);
      return await hello.completer.future as HelloOk;
    } on ArgumentError catch (error) {
      await _shutDown(
        NasFailure(NasFailureKind.closedByClient, 'Hello not sent: $error'),
      );
      rethrow;
    }
  }

  /// Sends [message] and completes with its reply (type = request + 1).
  /// Requests go out one at a time, in call order.
  ///
  /// Fails with [NasRequestError] when the server answers Error, with
  /// [NasFailure] when the connection ends first or the reply does not
  /// come within [requestTimeout] (which also closes the connection), and
  /// with [ArgumentError] when [message] cannot be encoded.
  Future<Message> request(Message message) {
    if (!_isClientRequest(message)) {
      throw ArgumentError.value(
        message.messageName,
        'message',
        'not a request this client may send (use start() / close())',
      );
    }
    final failure = _closedBy;
    if (failure != null) return Future.error(failure);
    final pending = _PendingRequest(message);
    _waiting.add(pending);
    _sendNext();
    return pending.completer.future;
  }

  /// Sends Ping and returns the time until Pong.
  Future<Duration> ping() async {
    final stopwatch = Stopwatch()..start();
    await request(const Ping());
    return stopwatch.elapsed;
  }

  /// Sends `Close NORMAL`, closes the link and fails waiting requests
  /// with [NasFailureKind.closedByClient]. Safe to call more than once.
  Future<void> close() => _shutDown(
    const NasFailure(NasFailureKind.closedByClient, 'closed by this app'),
    sendCloseNormal: true,
  );

  static bool _isClientRequest(Message message) =>
      message.messageType.isOdd &&
      message is! Hello &&
      message is! ErrorMessage;

  // ── Sending ─────────────────────────────────────────────────────────

  void _sendNext() {
    if (_closedBy != null ||
        _helloOk == null ||
        _inFlight != null ||
        _waiting.isEmpty) {
      return;
    }
    final pending = _waiting.removeFirst();
    try {
      _send(pending, requestTimeout, NasFailureKind.requestTimeout);
    } on ArgumentError catch (error) {
      pending.completer.completeError(error);
      _sendNext();
    }
  }

  /// Encodes and sends [pending] as the request in flight. Throws
  /// [ArgumentError] (nothing sent) when it cannot be encoded.
  void _send(
    _PendingRequest pending,
    Duration timeout,
    NasFailureKind timeoutKind,
  ) {
    final requestId = _nextRequestId;
    final frame = encodeFrame(pending.message, requestId);
    _nextRequestId = requestId >= maxRequestId ? 1 : requestId + 1;
    pending.requestId = requestId;
    _inFlight = pending;
    pending.timeoutTimer = Timer(
      timeout,
      () => _shutDown(
        NasFailure(
          timeoutKind,
          '${pending.message.messageName} got no reply in '
          '${timeout.inMilliseconds} ms',
        ),
      ),
    );
    _logFrame(Direction.sent, pending.message, requestId, frame);
    _restartPingTimer();
    _link
        .send(frame)
        .then<void>(
          (_) {},
          onError: (Object error) =>
              _shutDown(_linkFailure('send failed: $error')),
        );
  }

  // ── Receiving ───────────────────────────────────────────────────────

  void _onBytes(Uint8List piece) {
    if (_closedBy != null) return;
    for (final frame in _assembler.addBytes(piece)) {
      if (_closedBy != null) return;
      _onFrame(frame);
    }
    final assemblerFailure = _assembler.failure;
    if (_closedBy == null && assemblerFailure != null) {
      log?.note('malformed bytes from the server: $assemblerFailure');
      _shutDown(NasFailure(NasFailureKind.malformed, assemblerFailure));
    }
  }

  void _onFrame(Frame frame) {
    _restartPingTimer();
    switch (decodeMessage(frame.messageType, frame.payload)) {
      case DecodeBad(:final reason):
        log?.received(
          'malformed frame, id ${frame.requestId}: $reason',
          _frameBytesForLog(frame.messageType, frame.requestId, frame.payload),
        );
        _shutDown(NasFailure(NasFailureKind.malformed, reason));
      case DecodeOk(:final message):
        log?.received(
          _describeFrame(message, frame.requestId, frame.payload.length),
          _frameBytesForLog(
            frame.messageType,
            frame.requestId,
            frame.payload,
            // The device key must never reach the log (spec §7).
            isPayloadSecret: message is PairOk,
          ),
        );
        _onMessage(message, frame.requestId);
    }
  }

  void _onMessage(Message message, int requestId) {
    if (message is Close) {
      final detail = message.message.isEmpty ? '' : ' "${message.message}"';
      _shutDown(
        NasFailure(
          NasFailureKind.serverClosed,
          'server closed the connection: ${message.reasonName}$detail',
          closeReason: message.reason,
        ),
      );
      return;
    }
    final pending = _inFlight;
    if (pending == null || requestId != pending.requestId) {
      if (message is ErrorMessage) {
        // An Error that answers no readable request (request id 0).
        _shutDown(_serverErrorFailure(message));
      } else {
        _shutDown(
          NasFailure(
            NasFailureKind.unexpectedReply,
            '${message.messageName} with unknown request id $requestId',
          ),
        );
      }
      return;
    }
    if (message is ErrorMessage) {
      if (_helloOk == null) {
        _shutDown(_serverErrorFailure(message));
        return;
      }
      final error = NasRequestError.fromMessage(message);
      _finishInFlight();
      pending.completer.completeError(error);
      if (error.isFatal) {
        _shutDown(_serverErrorFailure(message));
      } else {
        _sendNext();
      }
      return;
    }
    if (message.messageType != pending.message.messageType + 1) {
      _shutDown(
        NasFailure(
          NasFailureKind.unexpectedReply,
          '${message.messageName} does not answer '
          '${pending.message.messageName} (request id $requestId)',
        ),
      );
      return;
    }
    if (message is HelloOk) {
      _onHelloOk(message);
      if (_closedBy != null) return;
    }
    _finishInFlight();
    pending.completer.complete(message);
    _sendNext();
  }

  void _onHelloOk(HelloOk helloOk) {
    if (helloOk.protocolVersion != protocolVersion) {
      _shutDown(
        NasFailure(
          NasFailureKind.versionMismatch,
          'server speaks protocol ${helloOk.protocolVersion}, '
          'this app speaks $protocolVersion',
        ),
      );
      return;
    }
    _helloOk = helloOk;
    _state.value = NasReady(helloOk);
    log?.note(
      'ready: ${helloOk.serverName} (${helloOk.serverSoftware}), '
      'device ${helloOk.deviceId}',
    );
    _restartPingTimer();
  }

  NasFailure _serverErrorFailure(ErrorMessage error) {
    final isVersionMismatch = error.knownCode == ErrorCode.versionMismatch;
    return NasFailure(
      isVersionMismatch
          ? NasFailureKind.versionMismatch
          : NasFailureKind.serverError,
      'server error ${error.codeName}: ${error.message}',
      errorCode: error.code,
    );
  }

  void _finishInFlight() {
    _inFlight?.timeoutTimer?.cancel();
    _inFlight = null;
  }

  void _onLinkError(Object error) =>
      _shutDown(_linkFailure('link failed: $error'));

  void _onLinkDone() => _shutDown(_linkFailure('the server ended the link'));

  NasFailure _linkFailure(String text) => _helloOk == null
      ? NasFailure(
          NasFailureKind.closedBeforeHello,
          '$text before HelloOk (maybe this phone is not paired)',
        )
      : NasFailure(NasFailureKind.linkClosed, text);

  // ── Keepalive ───────────────────────────────────────────────────────

  /// Any frame in or out counts as traffic and pushes the next Ping back.
  void _restartPingTimer() {
    _pingTimer?.cancel();
    if (_helloOk == null || _closedBy != null) return;
    _pingTimer = Timer(pingInterval, _onPingDue);
  }

  void _onPingDue() {
    if (_closedBy != null) return;
    if (_inFlight != null || _waiting.isNotEmpty) {
      // The request in flight has its own timeout.
      _restartPingTimer();
      return;
    }
    // A failure is already reported through [state].
    ping().then<void>((_) {}, onError: (Object _) {});
  }

  // ── Shutting down ───────────────────────────────────────────────────

  /// Ends the connection once: fails every waiting request with
  /// [failure], then closes the link. Later calls return the same future.
  Future<void> _shutDown(NasFailure failure, {bool sendCloseNormal = false}) {
    final linkClosed = _linkClosed;
    if (linkClosed != null) return linkClosed;
    _closedBy = failure;
    _pingTimer?.cancel();
    final inFlight = _inFlight;
    _finishInFlight();
    final failed = [?inFlight, ..._waiting];
    _waiting.clear();
    for (final pending in failed) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(failure);
      }
    }
    log?.note('connection closed: ${failure.message}');
    _state.value = NasClosed(failure);
    return _linkClosed = _closeLink(sendCloseNormal);
  }

  Future<void> _closeLink(bool sendCloseNormal) async {
    // Stops events at once; not awaited, so the link closes in this same
    // call when there is no Close to send.
    _subscription?.cancel().ignore();
    if (sendCloseNormal) {
      final close = Close(reason: CloseReason.normal.number, message: '');
      final frame = encodeFrame(close, 0);
      _logFrame(Direction.sent, close, 0, frame);
      try {
        await _link.send(frame);
      } catch (_) {
        // The link is already gone; nothing more to tell the server.
      }
    }
    try {
      await _link.close();
    } catch (_) {
      // Closing a broken socket may throw; it is closed either way.
    }
  }

  // ── Log ─────────────────────────────────────────────────────────────

  void _logFrame(
    Direction direction,
    Message message,
    int requestId,
    Uint8List frame,
  ) {
    final log = this.log;
    if (log == null) return;
    final payload = Uint8List.sublistView(frame, frameHeaderBytes);
    log.add(
      direction,
      _describeFrame(message, requestId, payload.length),
      _frameBytesForLog(
        message.messageType,
        requestId,
        payload,
        isPayloadSecret: message is PairOk,
      ),
    );
  }

  /// `HelloOk(...) · id 1 · 52 bytes`; Message.toString hides the PairOk
  /// key.
  static String _describeFrame(
    Message message,
    int requestId,
    int payloadBytes,
  ) => '$message · id $requestId · ${frameHeaderBytes + payloadBytes} bytes';

  /// A copy of the frame header and the start of the payload, at most
  /// [maxLoggedFrameBytes]; only the header when [isPayloadSecret].
  static Uint8List _frameBytesForLog(
    int messageType,
    int requestId,
    Uint8List payload, {
    bool isPayloadSecret = false,
  }) {
    final header = ByteData(frameHeaderBytes)
      ..setUint32(0, minFrameLengthBytes + payload.length)
      ..setUint16(4, messageType)
      ..setUint32(6, requestId);
    final keptPayloadBytes = isPayloadSecret
        ? 0
        : math.min(payload.length, maxLoggedFrameBytes - frameHeaderBytes);
    return (BytesBuilder()
          ..add(header.buffer.asUint8List())
          ..add(Uint8List.sublistView(payload, 0, keptPayloadBytes)))
        .toBytes();
  }
}
