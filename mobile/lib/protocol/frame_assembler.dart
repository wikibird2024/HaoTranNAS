/// Joins incoming byte pieces (as a Link delivers them, with no regard
/// for frame borders) into whole frames (spec §3):
/// lengthBytes u32 BE · messageType u16 BE · requestId u32 BE · payload.
///
/// The length field is checked as soon as its 4 bytes arrive
/// (`minFrameLengthBytes ..= maxFrameLengthBytes`), before any body byte
/// is buffered, so a bad peer cannot make the phone allocate a huge
/// buffer. After a failure the assembler stays failed: the connection
/// must be closed. Pure: no sockets. Never throws on bad bytes.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'limits.dart';

/// One whole frame. The message type is not checked here; that is
/// `decodeMessage`'s job.
final class Frame {
  const Frame({
    required this.messageType,
    required this.requestId,
    required this.payload,
  });

  final int messageType;
  final int requestId;
  final Uint8List payload;

  @override
  String toString() =>
      'Frame(messageType: 0x${messageType.toRadixString(16).padLeft(4, '0')}, '
      'requestId: $requestId, payload: ${payload.length} bytes)';
}

final class FrameAssembler {
  /// Gathers the 4 bytes of the length field.
  final Uint8List _lengthField = Uint8List(4);
  int _lengthFieldFilledBytes = 0;

  /// Everything after the length field (type, request id, payload);
  /// allocated only after the length passed its check.
  Uint8List? _body;
  int _bodyFilledBytes = 0;

  String? _failure;

  /// Why the stream was rejected, or null while it is fine.
  String? get failure => _failure;

  bool get hasFailed => _failure != null;

  /// Bytes received that do not make a whole frame yet.
  int get bufferedBytes => _lengthFieldFilledBytes + _bodyFilledBytes;

  /// Takes the next piece of the stream and returns the frames it
  /// completed, in order. Frames completed before a bad length field in
  /// the same piece are still returned; check [failure] after each call.
  /// Once failed, returns no frames.
  List<Frame> addBytes(Uint8List piece) {
    final frames = <Frame>[];
    var offsetBytes = 0;
    while (offsetBytes < piece.length && _failure == null) {
      final body = _body;
      if (body == null) {
        _lengthField[_lengthFieldFilledBytes++] = piece[offsetBytes++];
        if (_lengthFieldFilledBytes == 4) _startBody();
        continue;
      }
      final copyBytes = math.min(
        piece.length - offsetBytes,
        body.length - _bodyFilledBytes,
      );
      body.setRange(
        _bodyFilledBytes,
        _bodyFilledBytes + copyBytes,
        piece,
        offsetBytes,
      );
      _bodyFilledBytes += copyBytes;
      offsetBytes += copyBytes;
      if (_bodyFilledBytes == body.length) {
        frames.add(_finishFrame(body));
      }
    }
    return frames;
  }

  void _startBody() {
    final lengthBytes = ByteData.sublistView(_lengthField).getUint32(0);
    if (lengthBytes < minFrameLengthBytes ||
        lengthBytes > maxFrameLengthBytes) {
      _failure =
          'frame length_bytes $lengthBytes is outside '
          '$minFrameLengthBytes..=$maxFrameLengthBytes';
      return;
    }
    _body = Uint8List(lengthBytes);
    _bodyFilledBytes = 0;
  }

  Frame _finishFrame(Uint8List body) {
    _body = null;
    _bodyFilledBytes = 0;
    _lengthFieldFilledBytes = 0;
    final view = ByteData.sublistView(body);
    return Frame(
      messageType: view.getUint16(0),
      requestId: view.getUint32(2),
      payload: Uint8List.sublistView(body, 6),
    );
  }
}
