// APP_START handshake-retry policy helpers (#88).
//
// The BLE/USB handshake retry was an unbounded 3.5s hammer; on a slow device it
// churned the connect and starved the contact sync (stuck red bar). These pin
// the replacement policy: an exponential backoff that settles into a slow
// keep-alive (never a hard stop), and a send-gate that skips while an initial
// sync is in flight (mirroring the Web path).

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';

void main() {
  group('nextAppStartRetryDelay', () {
    test('ramps 3.5 -> 7 -> 14 -> 28 -> 56s then holds at 60s', () {
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(0),
        const Duration(milliseconds: 3500),
      );
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(1),
        const Duration(seconds: 7),
      );
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(2),
        const Duration(seconds: 14),
      );
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(3),
        const Duration(seconds: 28),
      );
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(4),
        const Duration(seconds: 56),
      );
      expect(
        MeshCoreConnector.nextAppStartRetryDelay(5),
        const Duration(seconds: 60),
      );
    });

    test('never hammers (>= 3.5s) and never exceeds the 60s keep-alive', () {
      for (var attempt = 0; attempt < 64; attempt++) {
        final d = MeshCoreConnector.nextAppStartRetryDelay(attempt);
        expect(d.inMilliseconds, greaterThanOrEqualTo(3500));
        expect(d.inMilliseconds, lessThanOrEqualTo(60000));
      }
    });
  });

  group('shouldSendAppStartRetry', () {
    test('sends only while connected, awaiting self-info, and not syncing', () {
      expect(
        MeshCoreConnector.shouldSendAppStartRetry(
          connected: true,
          awaitingSelfInfo: true,
          syncing: false,
        ),
        isTrue,
      );
    });

    test('does not send when disconnected', () {
      expect(
        MeshCoreConnector.shouldSendAppStartRetry(
          connected: false,
          awaitingSelfInfo: true,
          syncing: false,
        ),
        isFalse,
      );
    });

    test('does not send once the handshake is no longer awaited', () {
      expect(
        MeshCoreConnector.shouldSendAppStartRetry(
          connected: true,
          awaitingSelfInfo: false,
          syncing: false,
        ),
        isFalse,
      );
    });

    test('skips while an initial sync is in flight', () {
      expect(
        MeshCoreConnector.shouldSendAppStartRetry(
          connected: true,
          awaitingSelfInfo: true,
          syncing: true,
        ),
        isFalse,
      );
    });
  });
}
