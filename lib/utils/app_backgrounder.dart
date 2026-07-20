import 'package:flutter/services.dart';

import 'platform_info.dart';

/// Sends the app to the background without tearing it down.
///
/// `SystemNavigator.pop()` is NOT this: on Android it calls `finish()` on the
/// activity, which destroys the Flutter engine and drops the radio connection,
/// so reopening the app finds itself disconnected. `moveTaskToBack` leaves the
/// activity alive and simply hands focus back to whatever was in front before.
class AppBackgrounder {
  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/app_lifecycle',
  );

  /// Returns true when the app was actually backgrounded.
  ///
  /// Android only. Desktop windows are closed by their own chrome and iOS
  /// forbids programmatic backgrounding, so elsewhere this is a no-op and the
  /// caller should leave the press unhandled rather than act on it.
  static Future<bool> moveToBackground() async {
    if (!PlatformInfo.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('moveTaskToBack') ?? false;
    } on PlatformException catch (_) {
      // Surface nothing to the user: the fallback is simply that back does
      // nothing at the root, which is the pre-existing behaviour.
      return false;
    } on MissingPluginException catch (_) {
      return false;
    }
  }
}
