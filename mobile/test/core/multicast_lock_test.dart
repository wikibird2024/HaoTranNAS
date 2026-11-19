// The Android Wi-Fi multicast lock channel and withMulticastLock (stay in
// the phone app: the shared client has no Android code).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/core/transport/multicast_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MulticastLock calls the MainActivity channel', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(MulticastLock.channelName), (call) async {
          calls.add(call);
          return null;
        });

    final lock = MulticastLock();
    await lock.hold();
    await lock.release();

    expect(calls.map((call) => call.method), ['multicastLock', 'multicastLock']);
    expect(calls.map((call) => call.arguments), [
      {'hold': true},
      {'hold': false},
    ]);
  });

  group('withMulticastLock', () {
    final calls = <Object?>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(MulticastLock.channelName),
            (call) async {
              calls.add(call.arguments);
              return null;
            },
          );
    });

    test('holds, runs, releases, returns the result', () async {
      final result = await withMulticastLock(MulticastLock(), () async {
        calls.add('action');
        return 5;
      });
      expect(result, 5);
      expect(calls, [
        {'hold': true},
        'action',
        {'hold': false},
      ]);
    });

    test('releases when the action throws', () async {
      await expectLater(
        withMulticastLock<void>(
          MulticastLock(),
          () async => throw StateError('boom'),
        ),
        throwsStateError,
      );
      expect(calls, [
        {'hold': true},
        {'hold': false},
      ]);
    });

    test(
      'hold fails → action does not run, error goes to the caller',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(MulticastLock.channelName),
              (call) async => throw PlatformException(code: 'no_wifi'),
            );
        var didRun = false;
        await expectLater(
          withMulticastLock(MulticastLock(), () async => didRun = true),
          throwsA(isA<PlatformException>()),
        );
        expect(didRun, isFalse);
      },
    );
  });
}
