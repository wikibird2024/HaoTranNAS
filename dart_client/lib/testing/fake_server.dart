// A scripted server on a FakeLink: decodes what the phone sends and
// answers through [answer]. Used by the NasConnection tests.
import 'dart:typed_data';

import 'package:haotrannas_client/core/transport/link.dart';
import 'package:haotrannas_client/protocol/codec.dart';
import 'package:haotrannas_client/protocol/frame_assembler.dart';
import 'package:haotrannas_client/protocol/messages.dart';

const testHelloOk = HelloOk(
  protocolVersion: 1,
  serverSoftware: 'haotrannas-server 0.1.0',
  serverName: 'nas',
  deviceId: 1,
  chunkSizeBytes: 1048576,
  maxFrameLengthBytes: 4194304,
);

/// One frame the phone sent.
typedef SentFrame = ({int requestId, Message message});

class FakeServer {
  FakeServer({FakeLink? link}) : link = link ?? FakeLink() {
    this.link.onSend = _onSend;
  }

  final FakeLink link;
  final _assembler = FrameAssembler();

  /// Every frame the phone sent, decoded, in order.
  final sent = <SentFrame>[];

  /// The reply to a request; null = stay silent. Default: HelloOk for
  /// Hello, Pong for Ping, DeviceList for ListDevices.
  Message? Function(Message request) answer = defaultAnswer;

  /// Byte counts to cut each reply into; null = one piece.
  List<int>? replyPieceSizes;

  static Message? defaultAnswer(Message request) => switch (request) {
    Hello() => testHelloOk,
    Ping() => const Pong(),
    ListDevices() => const DeviceList(devices: []),
    _ => null,
  };

  List<Message> get sentMessages => [for (final frame in sent) frame.message];

  void _onSend(Uint8List bytes) {
    for (final frame in _assembler.addBytes(bytes)) {
      final result = decodeMessage(frame.messageType, frame.payload);
      final message = (result as DecodeOk).message;
      sent.add((requestId: frame.requestId, message: message));
      final reply = answer(message);
      if (reply != null) send(reply, frame.requestId);
    }
  }

  /// Plays [message] as if the server sent it, in [replyPieceSizes]
  /// pieces when set.
  void send(Message message, int requestId) {
    final frame = encodeFrame(message, requestId);
    final pieceSizes = replyPieceSizes;
    if (pieceSizes == null) {
      link.deliver(frame);
      return;
    }
    var offsetBytes = 0;
    for (final pieceBytes in pieceSizes) {
      link.deliver(frame.sublist(offsetBytes, offsetBytes + pieceBytes));
      offsetBytes += pieceBytes;
    }
    if (offsetBytes < frame.length) link.deliver(frame.sublist(offsetBytes));
  }
}
