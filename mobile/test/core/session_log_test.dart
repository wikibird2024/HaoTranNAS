// Adapted from Protocol Lab (test/core/log_export_test.dart, capacity test).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/core/log/session_log.dart';

void main() {
  test('entries keep time, direction, description and bytes', () {
    final time = DateTime.utc(2026, 11, 18, 10);
    var notifyCount = 0;
    final log = SessionLog(clock: () => time)
      ..addListener(() => notifyCount++)
      ..sent('Hello', Uint8List.fromList([1, 2, 3]))
      ..note('connected')
      ..received('HelloOk', Uint8List.fromList([4]));

    expect(log.length, 3);
    expect(log.entries.map((entry) => entry.direction), [
      Direction.sent,
      Direction.note,
      Direction.received,
    ]);
    expect(log.entryAt(0).description, 'Hello');
    expect(log.entryAt(0).bytes, [1, 2, 3]);
    expect(log.entryAt(1).bytes, isEmpty);
    expect(log.entryAt(2).time, time);
    expect(notifyCount, 3);

    log.clear();
    expect(log.length, 0);
    expect(notifyCount, 4);
  });

  test('log capacity drops the oldest', () {
    final small = SessionLog(capacity: 2)
      ..note('a')
      ..note('b')
      ..note('c');
    expect(small.entries.map((entry) => entry.description), ['b', 'c']);
  });
}
