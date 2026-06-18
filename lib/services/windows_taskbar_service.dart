import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Flashes the Windows taskbar button to draw attention — e.g. a new message
/// arriving while the app window is not in the foreground.
///
/// The native side (`windows/runner/flutter_window.cpp`) only flashes when the
/// window is not already the foreground window, so callers don't need to track
/// focus themselves. No-op on every non-Windows platform.
class WindowsTaskbarService {
  WindowsTaskbarService._();

  static const MethodChannel _channel = MethodChannel(
    'meshcore_open/windows_taskbar',
  );

  /// Flash the taskbar button if the window isn't focused. Safe on any platform
  /// (no-op off Windows) and harmless if the native handler isn't registered.
  static Future<void> flash() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('flash');
    } catch (e) {
      debugPrint('WindowsTaskbarService.flash failed: $e');
    }
  }
}
