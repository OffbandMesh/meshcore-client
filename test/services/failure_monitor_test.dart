import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/failure_monitor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Map<String, Object> _marker(Object? foreground, {bool dartError = false}) => {
  FailureMonitor.markerKey: jsonEncode({
    'foreground': foreground,
    'dartError': dartError,
  }),
};

Future<FailureKind?> _startAfter(Map<String, Object> previous) async {
  final m = FailureMonitor(prefs: await _prefs(previous));
  m.start(installHandlers: false);
  return m.pending;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('how the last run ended', () {
    test('a first run, or a clean exit, leaves nothing to offer', () async {
      expect(await _startAfter({}), isNull);
    });

    test('dying on screen is an unexpected exit', () async {
      expect(await _startAfter(_marker(true)), FailureKind.foregroundExit);
    });

    test('dying in the background is the OS reclaiming memory', () async {
      expect(await _startAfter(_marker(false)), isNull);
    });

    test('a marker that cannot say where the app was is asked about', () async {
      expect(await _startAfter(_marker(null)), FailureKind.unknownExit);
      expect(
        await _startAfter({FailureMonitor.markerKey: 'not json'}),
        FailureKind.unknownExit,
      );
    });

    test('on web only an unhandled error counts', () async {
      Future<FailureKind?> onWeb(Map<String, Object> previous) async {
        final m = FailureMonitor(prefs: await _prefs(previous), isWeb: true);
        m.start(installHandlers: false);
        return m.pending;
      }

      expect(await onWeb(_marker(true)), isNull);
      expect(await onWeb(_marker(null)), isNull);
      expect(
        await onWeb(_marker(true, dartError: true)),
        FailureKind.dartError,
      );
    });

    test('an unhandled Dart error wins over where the app was', () async {
      expect(
        await _startAfter(_marker(false, dartError: true)),
        FailureKind.dartError,
      );
    });
  });

  group('this run', () {
    late SharedPreferences prefs;
    late FailureMonitor m;
    Map<String, dynamic> marker() =>
        jsonDecode(prefs.getString(FailureMonitor.markerKey)!)
            as Map<String, dynamic>;

    setUp(() async {
      prefs = await _prefs();
      m = FailureMonitor(prefs: prefs)..start(installHandlers: false);
    });

    test('the marker follows the app on and off screen', () {
      expect(marker()['foreground'], isTrue);
      m.onLifecycle(AppLifecycleState.paused);
      expect(marker()['foreground'], isFalse);
      m.onLifecycle(AppLifecycleState.resumed);
      expect(marker()['foreground'], isTrue);
      m.onLifecycle(AppLifecycleState.hidden);
      expect(marker()['foreground'], isFalse);
    });

    test('a clean exit removes the marker', () {
      m.onLifecycle(AppLifecycleState.detached);
      expect(prefs.containsKey(FailureMonitor.markerKey), isFalse);
    });

    test('a Dart error is kept for the next launch', () async {
      m.recordDartError();
      expect(marker()['dartError'], isTrue);
      final next = FailureMonitor(prefs: prefs)..start(installHandlers: false);
      expect(next.pending, FailureKind.dartError);
      expect(marker()['dartError'], isFalse, reason: 'a new run starts clean');
    });

    test('Android exit records name the failure, backfill does not', () {
      m.recordExitReasons(['LOW_MEMORY', 'USER_REQUESTED'], backfill: false);
      expect(m.pending, isNull);
      m.recordExitReasons(['ANR'], backfill: true);
      expect(m.pending, isNull);
      m.recordExitReasons(['CRASH_NATIVE'], backfill: false);
      expect(m.pending, FailureKind.crash);
      m.recordExitReasons(['CRASH', 'ANR'], backfill: false);
      expect(m.pending, FailureKind.anr);
      m.resolve();
      expect(m.pending, isNull);
    });
  });

  test('a failed map tile is not the app breaking', () {
    expect(
      FailureMonitor.countsAsFailure(
        FlutterErrorDetails(
          exception: Exception('404'),
          library: 'image resource service',
        ),
      ),
      isFalse,
    );
    expect(
      FailureMonitor.countsAsFailure(
        FlutterErrorDetails(exception: Exception('x'), silent: true),
      ),
      isFalse,
    );
    expect(
      FailureMonitor.countsAsFailure(
        FlutterErrorDetails(exception: StateError('bad'), library: 'widgets'),
      ),
      isTrue,
    );
  });
}
