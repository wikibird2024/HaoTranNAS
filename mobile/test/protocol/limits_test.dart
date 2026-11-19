import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';

void main() {
  test('the largest ChunkData frame fits under the frame limit', () {
    // header + u64 field + u32 field + hash + u32 data length + data
    // (ChunkData's fixed-size fields as the Rust core lays them out).
    const largestChunkDataFrameBytes =
        frameHeaderBytes + 8 + 4 + hashBytes + 4 + chunkSizeBytes;
    // maxFrameLengthBytes counts the bytes after the u32 length field.
    expect(
      largestChunkDataFrameBytes,
      lessThanOrEqualTo(maxFrameLengthBytes + 4),
    );
  });

  test('a frame with an empty payload is exactly the minimum length', () {
    expect(frameHeaderBytes - 4, minFrameLengthBytes);
  });

  test('the client pings well before the server idles it out', () {
    expect(pingIntervalMs * 2, lessThan(idleTimeoutMs));
  });

  test('commit timeout grows with the file size, like the Rust core', () {
    expect(commitTimeoutMs(0), 30000);
    expect(commitTimeoutMs(20 * 1048576), 31000);
    // The largest file (64 GiB) gets about 55 minutes, not 30 seconds.
    expect(commitTimeoutMs(64 * 1073741824), 30000 + 3276800);
  });
}
