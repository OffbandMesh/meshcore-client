import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../utils/platform_info.dart';

/// Persists and restores the desktop window's position and size (#349).
///
/// The stock Flutter desktop runner never saved geometry, so the window always
/// reopened at a default frame. This service saves the frame on move/resize and
/// restores it on launch.
///
/// The restore is clamped against the currently-connected displays: a window
/// last placed on a monitor that is now unplugged must not reopen off-screen
/// where the user cannot reach it. If the saved frame does not overlap any
/// display enough to grab, it is discarded and the window opens at the default.
///
/// Desktop only (window_manager has no mobile/web backend); a no-op elsewhere.
class WindowGeometryService with WindowListener {
  WindowGeometryService._();
  static final WindowGeometryService instance = WindowGeometryService._();

  static const _prefsKey = 'window_geometry';
  static const _minWidth = 400.0;
  static const _minHeight = 300.0;
  // A window counts as reachable if at least this much of it overlaps a
  // display on both axes, so a sliver still on screen is recoverable.
  static const _minVisible = 80.0;

  Timer? _saveDebounce;

  /// Call once in main() before runApp, after PrefsManager.initialize().
  Future<void> initialize() async {
    if (!PlatformInfo.isDesktop) return;

    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(null, () async {
      await _restore();
      await windowManager.show();
      await windowManager.focus();
    });
    windowManager.addListener(this);
    // Intercept close so the final geometry is saved even if the user moves
    // then closes inside the debounce window; onWindowClose does the save and
    // then destroys the window (Gemini review).
    await windowManager.setPreventClose(true);
  }

  Future<void> _restore() async {
    final raw = PrefsManager.instance.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;

    Rect saved;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      saved = Rect.fromLTWH(
        (m['x'] as num).toDouble(),
        (m['y'] as num).toDouble(),
        (m['w'] as num).toDouble(),
        (m['h'] as num).toDouble(),
      );
    } catch (e) {
      // SAFELANE 6: never swallow. A corrupt value falls through to the default.
      appLogger.error(
        'Failed to decode saved window geometry; using default: $e',
        tag: 'Window',
      );
      return;
    }

    if (saved.width < _minWidth || saved.height < _minHeight) return;

    if (!await _isReachable(saved)) {
      appLogger.info(
        'Saved window geometry is off-screen (monitor likely unplugged); '
        'opening at the default position instead.',
        tag: 'Window',
      );
      return;
    }

    await windowManager.setBounds(saved);
  }

  /// True when [saved] overlaps some connected display's visible area by at
  /// least [_minVisible] on both axes.
  Future<bool> _isReachable(Rect saved) async {
    final displays = await screenRetriever.getAllDisplays();
    for (final d in displays) {
      // Use the visible pair when BOTH are known, else the total pair. Mixing a
      // visible origin with a total size makes a rect offset from the real
      // area (Gemini review). visiblePosition can be negative for a monitor
      // left of / above the primary, which intersect handles correctly.
      final Rect display;
      if (d.visiblePosition != null && d.visibleSize != null) {
        display = d.visiblePosition! & d.visibleSize!;
      } else {
        display = Offset.zero & d.size;
      }
      final overlap = saved.intersect(display);
      // intersect() can return negative width/height when the rects miss; only
      // a genuine overlap on both axes counts.
      if (overlap.width >= _minVisible && overlap.height >= _minVisible) {
        return true;
      }
    }
    return false;
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    try {
      final b = await windowManager.getBounds();
      await PrefsManager.instance.setString(
        _prefsKey,
        jsonEncode({'x': b.left, 'y': b.top, 'w': b.width, 'h': b.height}),
      );
    } catch (e) {
      appLogger.error('Failed to save window geometry: $e', tag: 'Window');
    }
  }

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  /// Fires because setPreventClose(true) intercepted the close. Save the final
  /// geometry, release resources, then actually close the window.
  @override
  Future<void> onWindowClose() async {
    _saveDebounce?.cancel();
    try {
      await _save();
    } finally {
      windowManager.removeListener(this);
      await windowManager.destroy();
    }
  }
}
