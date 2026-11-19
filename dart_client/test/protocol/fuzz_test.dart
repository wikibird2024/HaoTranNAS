// Random and damaged bytes must never make the decoders throw (spec §3).
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/protocol/codec.dart';
import 'package:haotrannas_client/protocol/frame_assembler.dart';
import 'package:haotrannas_client/protocol/messages.dart';

import 'vector_files.dart';

const payloadsPerType = 2000;
const streamCount = 300;

/// Bytes like [source] with a few of them changed, cut short or grown.
Uint8List damage(Uint8List source, Random random) {
  final bytes = Uint8List.fromList(source);
  final changeCount = 1 + random.nextInt(4);
  for (var i = 0; i < changeCount && bytes.isNotEmpty; i++) {
    bytes[random.nextInt(bytes.length)] = random.nextInt(256);
  }
  switch (random.nextInt(4)) {
    case 0:
      return Uint8List.sublistView(bytes, 0, random.nextInt(bytes.length + 1));
    case 1:
      return Uint8List.fromList([
        ...bytes,
        for (var i = 0; i < 1 + random.nextInt(8); i++) random.nextInt(256),
      ]);
    default:
      return bytes;
  }
}

Uint8List randomBytes(Random random, int maxLengthBytes) => Uint8List.fromList([
  for (var i = 0; i < random.nextInt(maxLengthBytes + 1); i++)
    random.nextInt(256),
]);

void main() {
  final validVectors = [
    for (final vector in loadVectorFile('messages.json')['valid'] as List)
      vector as Map<String, dynamic>,
  ];
  final payloadsByType = <int, List<Uint8List>>{};
  final validFrames = <Uint8List>[];
  for (final vector in validVectors) {
    final frameBytes = frameBytesOf(vector);
    validFrames.add(frameBytes);
    final messageType = messageFromVector(vector).messageType;
    payloadsByType
        .putIfAbsent(messageType, () => [])
        .add(Uint8List.sublistView(frameBytes, 10));
  }

  test('decodeMessage never throws: $payloadsPerType payloads per type', () {
    final random = Random(2026);
    var decodedCount = 0;
    var rejectedCount = 0;
    for (final messageType in [...MessageType.all, 0, 0x0999, 0xffff]) {
      final samples = payloadsByType[messageType] ?? [Uint8List(0)];
      for (var round = 0; round < payloadsPerType; round++) {
        // Half pure noise, half damaged real payloads.
        final payload = round.isEven
            ? randomBytes(random, 80)
            : damage(samples[random.nextInt(samples.length)], random);
        final result = decodeMessage(messageType, payload);
        switch (result) {
          case DecodeOk():
            decodedCount++;
            // Anything that decodes must encode back to the same bytes.
            expect(encodePayload(result.message), payload);
          case DecodeBad():
            rejectedCount++;
        }
      }
    }
    expect(
      decodedCount + rejectedCount,
      (MessageType.all.length + 3) * payloadsPerType,
    );
  });

  test('FrameAssembler never throws on random streams', () {
    final random = Random(2026);
    for (var round = 0; round < streamCount; round++) {
      // Real frames, some damaged, plus noise, cut into random pieces.
      final stream = BytesBuilder();
      for (var i = 0; i < 1 + random.nextInt(6); i++) {
        final frame = validFrames[random.nextInt(validFrames.length)];
        stream.add(random.nextInt(3) == 0 ? damage(frame, random) : frame);
        if (random.nextInt(5) == 0) stream.add(randomBytes(random, 20));
      }
      final streamBytes = stream.toBytes();
      final assembler = FrameAssembler();
      var offsetBytes = 0;
      while (offsetBytes < streamBytes.length) {
        final pieceBytes = min(
          1 + random.nextInt(64),
          streamBytes.length - offsetBytes,
        );
        final frames = assembler.addBytes(
          Uint8List.sublistView(
            streamBytes,
            offsetBytes,
            offsetBytes + pieceBytes,
          ),
        );
        offsetBytes += pieceBytes;
        for (final frame in frames) {
          decodeMessage(frame.messageType, frame.payload);
        }
      }
      if (assembler.hasFailed) {
        expect(assembler.addBytes(Uint8List.fromList([0, 0, 0, 6])), isEmpty);
      }
    }
  });

  test('FrameAssembler never throws on pure noise', () {
    final random = Random(2026);
    for (var round = 0; round < streamCount; round++) {
      final assembler = FrameAssembler();
      for (var piece = 0; piece < 20; piece++) {
        assembler.addBytes(randomBytes(random, 32));
      }
    }
  });
}
