import 'package:flutter/services.dart';

/// Dart side of the Wi-Fi multicast lock in MainActivity.kt (pattern from
/// Protocol Lab). Android drops multicast packets (mDNS discovery, see
/// `mdns_socket.dart`) unless an app holds this lock. Hold it only while
/// discovering: it costs battery.
///
/// Throws [PlatformException] or [MissingPluginException] (not Android,
/// widget tests) when the native side fails or is missing; the caller
/// decides whether discovery goes on without it.
class MulticastLock {
  MulticastLock({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Must match `MULTICAST_CHANNEL` in MainActivity.kt.
  static const channelName = 'vn.haotran.haotrannas_mobile/multicast';

  final MethodChannel _channel;

  Future<void> hold() => _setHeld(true);

  Future<void> release() => _setHeld(false);

  Future<void> _setHeld(bool isHeld) =>
      _channel.invokeMethod<void>('multicastLock', {'hold': isHeld});
}
