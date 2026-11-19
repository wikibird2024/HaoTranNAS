// Debug log screen: entries newest first with direction, time and hex;
// a PairOk frame never shows its key bytes. Author: Hao Tran.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/core/log/session_log.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/ui/debug_log_screen.dart';

import 'ui_fakes.dart';

/// A frame header (length, type, request id 1) + [payload].
Uint8List frame(int messageType, List<int> payload) {
  final header = ByteData(10)
    ..setUint32(0, 6 + payload.length)
    ..setUint16(4, messageType)
    ..setUint32(6, 1);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

void main() {
  /// Bytes that stand for a device key: must never be on screen.
  final keyBytes = List.filled(40, 0xAB);

  test('PairOk shows only its header, even when bytes include the key', () {
    final entry = LogEntry(
      time: DateTime(2026),
      direction: Direction.received,
      description: 'something',
      bytes: frame(MessageType.pairOk, keyBytes),
    );
    final preview = logBytesPreview(entry);
    expect(preview, contains(keyRedactedText));
    expect(preview, isNot(contains('ab')));
  });

  test('other frames show the first 32 bytes and …', () {
    final entry = LogEntry(
      time: DateTime(2026),
      direction: Direction.sent,
      description: 'Ping',
      bytes: frame(MessageType.ping, List.filled(40, 0x11)),
    );
    final preview = logBytesPreview(entry);
    expect(preview.split(' ').where((part) => part == '11'), hasLength(22));
    expect(preview, endsWith('…'));
  });

  testWidgets('screen lists entries newest first, key redacted', (
    tester,
  ) async {
    final log = SessionLog(clock: () => DateTime(2026, 11, 19, 14, 5, 9, 123))
      ..sent('Hello(...) · id 1 · 40 bytes', frame(MessageType.hello, [0, 1]))
      ..received(
        'PairOk(deviceId: 3, deviceKeyPkcs8Der: <key redacted>)',
        frame(MessageType.pairOk, keyBytes),
      )
      ..note('connection closed');
    await pumpScreen(
      tester,
      const DebugLogScreen(),
      overrides: [sessionLogProvider.overrideWithValue(log)],
    );

    expect(find.text('connection closed'), findsOneWidget);
    expect(find.textContaining('→'), findsOneWidget);
    expect(find.textContaining('←'), findsOneWidget);
    expect(find.textContaining('14:05:09.123'), findsNWidgets(3));
    expect(find.textContaining(keyRedactedText), findsNWidgets(2));
    expect(find.textContaining('ab ab'), findsNothing);

    // Newest first: the note is above the PairOk line.
    final noteTop = tester.getTopLeft(find.text('connection closed')).dy;
    final pairOkTop = tester.getTopLeft(find.textContaining('PairOk(')).dy;
    expect(noteTop, lessThan(pairOkTop));

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing sent or received yet.'), findsOneWidget);
  });
}
