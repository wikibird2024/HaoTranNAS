/// Android's battery saver ("battery optimization") may stop the
/// automatic backup job; many phones (Samsung, Xiaomi) do it hard. This
/// asks the phone to leave the app alone (D-047). Native side:
/// `MainActivity.kt`. Author: Hao Tran.
///
/// ```
///  Automatic backup turned on ─► isExempt? ─ no ─► ask (system dialog)
///  Settings tile ─────────────► isExempt? ─ no ─► "Allow" ─► ask
/// ```
library;

import 'package:flutter/services.dart';

/// Is the app exempt from the battery saver, and asking for it.
abstract interface class BatteryExemption {
  /// True = the battery saver leaves background backups alone.
  Future<bool> isExempt();

  /// Shows the system's dialog; returns before the user answers.
  Future<void> ask();
}

/// The phone's [BatteryExemption]. Never throws: a phone without the
/// channel counts as exempt (nothing to ask).
class PlatformBatteryExemption implements BatteryExemption {
  const PlatformBatteryExemption();

  /// Must match BATTERY_CHANNEL in `MainActivity.kt`.
  static const _channel = MethodChannel('vn.haotran.haotrannas_mobile/battery');

  @override
  Future<bool> isExempt() async {
    try {
      return await _channel.invokeMethod<bool>('isExempt') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> ask() async {
    try {
      await _channel.invokeMethod<void>('ask');
    } on PlatformException {
      // No dialog on this phone: the Settings tile still tells the user.
    } on MissingPluginException {
      // Same.
    }
  }
}
