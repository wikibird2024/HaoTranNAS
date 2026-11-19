// Codec, assembler, message and error-code checks beyond the vectors.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/core/bytes/hex.dart';
import 'package:haotrannas_client/protocol/codec.dart';
import 'package:haotrannas_client/protocol/error_codes.dart';
import 'package:haotrannas_client/protocol/frame_assembler.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/messages.dart';

void main() {
  group('PairOk never shows its key', () {
    final key = Uint8List.fromList(List.generate(40, (i) => 0xa0 + (i % 16)));
    final message = PairOk(
      deviceId: 7,
      deviceCertDer: parseHex('3082010a0201'),
      deviceKeyPkcs8Der: key,
      serverCertSha256: Uint8List(32),
    );

    test('toString prints <key redacted>', () {
      final text = message.toString();
      expect(text, contains('<key redacted>'));
      expect(text, isNot(contains(toHex(key, separator: ''))));
      expect(text, isNot(contains(toHex(key))));
      expect(text, isNot(contains(key.toString())));
    });

    test('also inside DecodeOk', () {
      final text = DecodeOk(message).toString();
      expect(text, contains('<key redacted>'));
      expect(text, isNot(contains(toHex(key, separator: ''))));
    });

    test('a short key is redacted too (short byte lists print as hex)', () {
      final shortKey = parseHex('308187020100');
      final shortMessage = PairOk(
        deviceId: 7,
        deviceCertDer: Uint8List(0),
        deviceKeyPkcs8Der: shortKey,
        serverCertSha256: Uint8List(32),
      );
      expect(shortMessage.toString(), isNot(contains('308187020100')));
    });
  });

  group('value equality', () {
    test('byte lists compare by content', () {
      final first = ReadChunk(chunkSha256: Uint8List(32));
      final second = ReadChunk(chunkSha256: Uint8List(32));
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first, isNot(ReadChunk(chunkSha256: Uint8List(32)..[0] = 1)));
    });

    test('different types with the same fields are not equal', () {
      expect(const Ping(), isNot(const Pong()));
      expect(const Commit(uploadId: 1), isNot(const CommitOk(versionId: 1)));
    });
  });

  group('error codes and close reasons', () {
    test('known numbers and fatal flags', () {
      expect(ErrorCode.fromNumber(1), ErrorCode.malformedFrame);
      expect(ErrorCode.malformedFrame.isFatal, isTrue);
      expect(ErrorCode.notFound.number, 40);
      expect(ErrorCode.notFound.isFatal, isFalse);
      expect(ErrorCode.shuttingDown.isFatal, isTrue);
      expect(ErrorCode.values, hasLength(20));
      expect(CloseReason.pairedReconnect.number, 5);
    });

    test('unknown numbers are kept and shown as UNKNOWN(n)', () {
      const error = ErrorMessage(code: 999, message: 'from a newer server');
      expect(error.knownCode, isNull);
      expect(error.codeName, 'UNKNOWN(999)');
      expect(error.toString(), contains('UNKNOWN(999)'));
      const close = Close(reason: 9, message: '');
      expect(close.knownReason, isNull);
      expect(close.reasonName, 'UNKNOWN(9)');
      const known = Close(reason: 2, message: '');
      expect(known.reasonName, 'IDLE_TIMEOUT');
    });
  });

  group('decodeMessage', () {
    test('type 0 and unknown types are DecodeBad', () {
      expect(decodeMessage(0, Uint8List(0)), isA<DecodeBad>());
      expect(decodeMessage(0x0999, Uint8List(0)), isA<DecodeBad>());
    });

    test('dir entry kind 0 is malformed', () {
      final payload = parseHex(
        '00000001 000178 00 0000000000000000 0000000000000000 '
        '0000000000000000 00',
      );
      expect(decodeMessage(MessageType.dirEntries, payload), isA<DecodeBad>());
    });

    test('string limit is per field: 1024-byte path ok, 65-byte name not', () {
      final path = 'p' * maxPathBytes;
      final frame = encodeFrame(
        ReadFile(deviceId: 0, path: path, versionId: 0),
        1,
      );
      final result = decodeMessage(
        MessageType.readFile,
        Uint8List.sublistView(frame, frameHeaderBytes),
      );
      expect(
        (result as DecodeOk).message,
        ReadFile(deviceId: 0, path: path, versionId: 0),
      );
      expect(
        () => encodeFrame(PairRequest(code: 'c' * (maxNameBytes + 1)), 1),
        throwsArgumentError,
      );
    });
  });

  group('encodeFrame rejects caller bugs', () {
    test('request id must be a u32', () {
      expect(() => encodeFrame(const Ping(), -1), throwsArgumentError);
      expect(() => encodeFrame(const Ping(), 0x100000000), throwsArgumentError);
    });

    test('frame over 4 MiB', () {
      final message = ChunkContent(
        chunkSha256: Uint8List(32),
        data: Uint8List(maxFrameLengthBytes),
      );
      expect(() => encodeFrame(message, 1), throwsArgumentError);
    });

    test('largest ChunkData frame (1 MiB data) encodes and decodes', () {
      final message = ChunkData(
        uploadId: 1,
        chunkIndex: 0,
        chunkSha256: Uint8List(32),
        data: Uint8List(chunkSizeBytes),
      );
      final frame = encodeFrame(message, 1);
      expect(frame.length, 1048634);
      final frames = FrameAssembler().addBytes(frame);
      final result = decodeMessage(
        frames.single.messageType,
        frames.single.payload,
      );
      expect((result as DecodeOk).message, message);
    });
  });

  group('FrameAssembler', () {
    test('length at the max is accepted from the header alone', () {
      final assembler = FrameAssembler();
      assembler.addBytes(parseHex('00400000 0003'));
      expect(assembler.hasFailed, isFalse);
      expect(assembler.bufferedBytes, 6);
    });

    test('stays failed and returns nothing after a bad length', () {
      final assembler = FrameAssembler();
      assembler.addBytes(parseHex('00000005'));
      expect(assembler.hasFailed, isTrue);
      expect(assembler.addBytes(parseHex('00000006 0003 00000001')), isEmpty);
      expect(assembler.hasFailed, isTrue);
    });

    test('a good frame before a bad length in the same piece is returned', () {
      final assembler = FrameAssembler();
      final frames = assembler.addBytes(
        parseHex('00000006 0003 00000002 ffffffff'),
      );
      expect(frames, hasLength(1));
      expect(frames.single.requestId, 2);
      expect(assembler.hasFailed, isTrue);
    });

    test('one byte at a time', () {
      final frame = encodeFrame(
        const Hello(protocolVersion: 1, clientSoftware: 'x', deviceName: 'y'),
        5,
      );
      final assembler = FrameAssembler();
      final frames = <Frame>[];
      for (final byte in frame) {
        frames.addAll(assembler.addBytes(Uint8List.fromList([byte])));
      }
      expect(frames, hasLength(1));
      expect(frames.single.requestId, 5);
      expect(assembler.bufferedBytes, 0);
    });
  });
}
