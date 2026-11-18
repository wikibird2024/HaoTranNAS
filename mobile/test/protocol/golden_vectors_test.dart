// Checks the Dart codec against protocol/vectors/messages.json (spec §15).
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/protocol/codec.dart';
import 'package:haotrannas_mobile/protocol/frame_assembler.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import 'vector_files.dart';

const expectedValidCount = 37;
const expectedInvalidCount = 18;

void main() {
  final vectorFile = loadVectorFile('messages.json');
  final validVectors = [
    for (final vector in vectorFile['valid'] as List)
      vector as Map<String, dynamic>,
  ];
  final invalidVectors = [
    for (final vector in vectorFile['invalid'] as List)
      vector as Map<String, dynamic>,
  ];

  test('vector counts: $expectedValidCount valid, '
      '$expectedInvalidCount invalid', () {
    expect(validVectors, hasLength(expectedValidCount));
    expect(invalidVectors, hasLength(expectedInvalidCount));
  });

  test('every message type has at least one valid vector', () {
    final coveredTypes = {
      for (final vector in validVectors) messageFromVector(vector).messageType,
    };
    expect(coveredTypes, MessageType.all.toSet());
  });

  group('valid', () {
    for (final vector in validVectors) {
      test('${vector['name']}: decodes to its fields and encodes back', () {
        final frameBytes = frameBytesOf(vector);
        final expected = messageFromVector(vector);
        final requestId = vector['request_id'] as int;

        final assembler = FrameAssembler();
        final frames = assembler.addBytes(frameBytes);
        expect(assembler.failure, isNull);
        expect(frames, hasLength(1));
        expect(assembler.bufferedBytes, 0);
        expect(frames.single.requestId, requestId);
        expect(frames.single.messageType, expected.messageType);

        final result = decodeMessage(
          frames.single.messageType,
          frames.single.payload,
        );
        expect(result, isA<DecodeOk>());
        expect((result as DecodeOk).message, expected);

        expect(encodeFrame(expected, requestId), frameBytes);
      });
    }
  });

  group('invalid', () {
    for (final vector in invalidVectors) {
      final stage = vector['stage'] as String;
      test('${vector['name']} ($stage): rejected, ${vector['why']}', () {
        expect(vector['expect_error'], 'MALFORMED_FRAME');
        final frameBytes = frameBytesOf(vector);
        final assembler = FrameAssembler();
        final frames = assembler.addBytes(frameBytes);
        switch (stage) {
          case 'header':
            expect(assembler.hasFailed, isTrue);
            expect(frames, isEmpty);
          case 'payload':
            expect(assembler.failure, isNull);
            expect(frames, hasLength(1));
            final result = decodeMessage(
              frames.single.messageType,
              frames.single.payload,
            );
            expect(result, isA<DecodeBad>(), reason: '$result');
          default:
            fail('unknown stage $stage');
        }
      });
    }
  });

  test('header-stage failures are found from the 4 length bytes alone', () {
    for (final vector in invalidVectors.where(
      (vector) => vector['stage'] == 'header',
    )) {
      final assembler = FrameAssembler();
      assembler.addBytes(Uint8List.sublistView(frameBytesOf(vector), 0, 4));
      expect(assembler.hasFailed, isTrue, reason: '${vector['name']}');
    }
  });

  test('all valid frames, fed in random pieces of 1..97 bytes, give the '
      'same messages in order', () {
    final stream = BytesBuilder();
    final expected = <(int, Message)>[];
    for (final vector in validVectors) {
      stream.add(frameBytesOf(vector));
      expected.add((vector['request_id'] as int, messageFromVector(vector)));
    }
    final streamBytes = stream.toBytes();

    final random = Random(2026);
    final assembler = FrameAssembler();
    final received = <(int, Message)>[];
    var offsetBytes = 0;
    var pieceCount = 0;
    while (offsetBytes < streamBytes.length) {
      final pieceBytes = min(
        1 + random.nextInt(97),
        streamBytes.length - offsetBytes,
      );
      final piece = Uint8List.sublistView(
        streamBytes,
        offsetBytes,
        offsetBytes + pieceBytes,
      );
      offsetBytes += pieceBytes;
      pieceCount++;
      for (final frame in assembler.addBytes(piece)) {
        final result = decodeMessage(frame.messageType, frame.payload);
        expect(result, isA<DecodeOk>());
        received.add((frame.requestId, (result as DecodeOk).message));
      }
    }
    expect(assembler.failure, isNull);
    expect(assembler.bufferedBytes, 0);
    expect(pieceCount, greaterThan(validVectors.length));
    expect(received, expected);
  });
}
