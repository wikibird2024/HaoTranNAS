import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';

void main() {
  test('the largest ChunkData frame fits under the frame limit', () {
    // header + u64 field + u32 field + hash + u32 data length + data
    // (ChunkData's fixed-size fields as the Rust core lays them out).
    const largestChunkDataFrameBytes =
        frameHeaderBytes + 8 + 4 + hashBytes + 4 + chunkSizeBytes;
    // maxFrameLengthBytes counts the bytes after the u32 length field.
    expect(largestChunkDataFrameBytes, lessThanOrEqualTo(maxFrameLengthBytes + 4));
  });

  test('a frame with an empty payload is exactly the minimum length', () {
    expect(frameHeaderBytes - 4, minFrameLengthBytes);
  });

  test('the client pings well before the server idles it out', () {
    expect(pingIntervalMs * 2, lessThan(idleTimeoutMs));
  });
}
