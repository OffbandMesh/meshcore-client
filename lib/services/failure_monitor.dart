import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';

/// Why the last run is worth sending logs about.
enum FailureKind {
  /// Android says the process crashed (Java or native).
  crash,

  /// Android says the process stopped responding.
  anr,

  /// An error reached the top of the Dart code.
  dartError,

  /// The run ended while the app was on screen, with no clean exit.
  foregroundExit,

  /// The run ended and whether it was on screen is not known.
  unknownExit,
}

/// Notices a run that ended badly so the next launch can offer to send the
/// logs (#1213).
///
/// A run marker is written at start and kept up to date with whether the app
/// is on screen. A clean exit removes it. So at the next start, a marker that
/// says "on screen" means the app died while the user was looking at it; one
/// that says "in the background" means the OS reclaimed memory, which is not a
/// failure. Android exit records and unhandled Dart errors are recorded too.
class FailureMonitor extends ChangeNotifier {
  FailureMonitor({SharedPreferences? prefs, this.isWeb = kIsWeb})
    : _prefsOverride = prefs;

  final bool isWeb;

  static final FailureMonitor instance = FailureMonitor();

  static const String markerKey = 'run_marker_v1';

  final SharedPreferences? _prefsOverride;
  SharedPreferences get _prefs => _prefsOverride ?? PrefsManager.instance;

  FailureKind? _pending;
  AppLifecycleListener? _lifecycle;
  bool _dartError = false;
  bool _foreground = true;

  /// The previous run's failure, until the user answers the offer.
  FailureKind? get pending => _pending;

  /// Read what the previous run left, then start this run's marker. Call once,
  /// after prefs are ready and before `runApp`.
  void start({bool installHandlers = true}) {
    _pending = _readPrevious();
    if (_pending != null) {
      appLogger.warn(
        'Previous run ended badly: ${_pending!.name}',
        tag: 'FailureMonitor',
      );
    }
    _foreground = true;
    _dartError = false;
    _writeMarker();
    if (installHandlers) _installHandlers();
  }

  FailureKind? _readPrevious() {
    final raw = _prefs.getString(markerKey);
    if (raw == null) return null;
    try {
      final marker = jsonDecode(raw) as Map<String, dynamic>;
      if (marker['dartError'] == true) return FailureKind.dartError;
      // Closing a browser tab is not an exit Flutter can see, so on web only
      // an unhandled error counts: a marker left on screen means nothing.
      if (isWeb) return null;
      return switch (marker['foreground']) {
        true => FailureKind.foregroundExit,
        false => null,
        _ => FailureKind.unknownExit,
      };
    } catch (_) {
      return FailureKind.unknownExit;
    }
  }

  void _writeMarker() {
    _prefs.setString(
      markerKey,
      jsonEncode({'foreground': _foreground, 'dartError': _dartError}),
    );
  }

  void _installHandlers() {
    final priorFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      if (countsAsFailure(details)) recordDartError();
      priorFlutter?.call(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final priorDispatcher = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      recordDartError();
      appLogger.error('Unhandled error: $error\n$stack', tag: 'FailureMonitor');
      return priorDispatcher?.call(error, stack) ?? false;
    };
    _lifecycle = AppLifecycleListener(
      onStateChange: onLifecycle,
      onExitRequested: () async {
        await markCleanExit();
        return AppExitResponse.exit;
      },
    );
  }

  /// Image loads that fail (a missing map tile) are reported as Flutter
  /// errors but are not the app breaking.
  static bool countsAsFailure(FlutterErrorDetails details) =>
      !details.silent && details.library != 'image resource service';

  @visibleForTesting
  void onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      markCleanExit();
      return;
    }
    final foreground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _writeMarker();
  }

  void recordDartError() {
    if (_dartError) return;
    _dartError = true;
    _writeMarker();
  }

  /// Awaited before a desktop window is allowed to close, so the removal
  /// lands before the process ends.
  Future<void> markCleanExit() => _prefs.remove(markerKey);

  /// Android exit records read at this start (#906). Backfilled records,
  /// read on the first launch with the reader, are old news and not offered.
  void recordExitReasons(Iterable<String> reasons, {required bool backfill}) {
    if (backfill) return;
    final set = reasons.toSet();
    final kind = set.contains('ANR')
        ? FailureKind.anr
        : (set.contains('CRASH') || set.contains('CRASH_NATIVE'))
        ? FailureKind.crash
        : null;
    if (kind == null) return;
    _pending = kind;
    notifyListeners();
  }

  /// The user answered the offer, whichever way.
  void resolve() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}
