// Bounded, interruptible auto-reconnect (#997, design on #995).
//
// 2026-10-25: after a T1000-E dropped, the Windows client retried it about
// every 14 s for 7.7 hours, and nothing else could connect meanwhile. Two
// causes: every automatic attempt reset the attempt counter, and every connect
// path refused to start while an automatic attempt held the state at
// `connecting`, the BLE and USB-screen paths silently.

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _radio = 'E1:2C:3A:4B:5C:6D';

void main() {
  late MeshCoreConnector connector;
  late AppDebugLogService log;

  bool logged(String fragment) =>
      log.entries.any((e) => e.message.contains(fragment));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    log = AppDebugLogService()..setEnabled(true);
    connector = MeshCoreConnector()..setAppDebugLogServiceForTest(log);
    connector.primeAutoReconnectForTest(_radio);
  });

  tearDown(() => connector.stopAutoReconnect());

  // The radio drops; the retry is scheduled; the attempt starts and fails.
  Future<void> failOneAttempt() async {
    connector.beginAutoReconnectAttemptForTest();
    await connector.disconnect(manual: false);
  }

  group('the retry is bounded and backs off (#997 items 1, 2)', () {
    test('an automatic attempt does not reset the attempt count', () async {
      await connector.disconnect(manual: false);
      expect(connector.autoReconnectAttempt, 1);

      await failOneAttempt();

      expect(
        connector.autoReconnectAttempt,
        2,
        reason:
            'the bug: each automatic attempt reset this to 0, so the '
            'delay stayed at 1 s forever',
      );
    });

    test('the retry gives up after five attempts', () async {
      await connector.disconnect(manual: false);
      for (var i = 0; i < 5; i++) {
        await failOneAttempt();
      }

      expect(connector.autoReconnectGaveUp, isTrue);
      expect(connector.isAutoReconnecting, isFalse);
      expect(connector.isAutoReconnectScheduled, isFalse);
      expect(logged('Auto-reconnect stopped'), isTrue);
    });
  });

  group('the user can always take over (#997 items 3, 4, 5)', () {
    test('Stop ends an in-flight automatic attempt', () async {
      connector.beginAutoReconnectAttemptForTest();
      expect(connector.isAutoReconnecting, isTrue);

      await connector.stopAutoReconnect();

      expect(connector.state, MeshCoreConnectionState.disconnected);
      expect(connector.isAutoReconnecting, isFalse);
      expect(connector.isAutoReconnectScheduled, isFalse);
    });

    test('Stop also cancels a scheduled retry', () async {
      await connector.disconnect(manual: false);
      expect(connector.isAutoReconnectScheduled, isTrue);

      await connector.stopAutoReconnect();

      expect(connector.isAutoReconnectScheduled, isFalse);
      expect(connector.isAutoReconnecting, isFalse);
    });

    test(
      'a TCP connect started during an automatic attempt is not refused',
      () async {
        connector.beginAutoReconnectAttemptForTest();

        // Nothing listens on port 9 here; the connect fails, which is fine. The
        // point is that it is attempted rather than refused.
        try {
          await connector.connectTcp(host: '127.0.0.1', port: 9);
        } catch (_) {}

        expect(logged('connectTcp ignored'), isFalse);
        expect(logged('abandoning automatic reconnect'), isTrue);
      },
    );

    test('a BLE connect refused while connected says so in the log', () async {
      connector.setConnectedForTest();

      await connector.connect(BluetoothDevice.fromId('00:11:22:33:44:55'));

      expect(logged('connect ignored: already'), isTrue);
    });
  });
}
