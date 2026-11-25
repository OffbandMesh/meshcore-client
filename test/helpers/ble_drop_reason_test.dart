// #1186: a BLE drop must log why the link ended. iOS and Android give a reason
// code; Windows, Linux and web give none, and the line says so (#1187).

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/ble_drop_reason.dart';

void main() {
  String line({
    DisconnectReason? reason,
    String platform = 'iOS',
    bool reports = true,
    int secs = 0,
    AppLifecycleState? lifecycle = AppLifecycleState.resumed,
  }) => describeBleDrop(
    reason: reason,
    platform: platform,
    platformReportsReason: reports,
    sinceLastRx: Duration(seconds: secs),
    lifecycle: lifecycle,
  );

  test('iOS: the CoreBluetooth code and text', () {
    final l = line(
      reason: DisconnectReason(
        ErrorPlatform.apple,
        15,
        'Failed to encrypt the connection',
      ),
    );
    expect(l, contains('apple-code 15: Failed to encrypt the connection'));
    expect(l, contains('dropped by iOS'));
  });

  test('Android: the HCI status code and name', () {
    final l = line(
      platform: 'Android',
      reason: DisconnectReason(
        ErrorPlatform.android,
        8,
        'LINK_SUPERVISION_TIMEOUT',
      ),
    );
    expect(l, contains('android-code 8: LINK_SUPERVISION_TIMEOUT'));
  });

  test('a code with no text still shows the code', () {
    final l = line(reason: DisconnectReason(ErrorPlatform.apple, 7, null));
    expect(l, contains('apple-code 7)'));
  });

  test('a code with empty text shows only the code', () {
    final l = line(reason: DisconnectReason(ErrorPlatform.apple, 7, ''));
    expect(l, contains('apple-code 7)'));
    expect(l, isNot(contains('7: ')));
  });

  test('a reporting platform that gave no code says so', () {
    final l = line(reason: DisconnectReason(ErrorPlatform.apple, null, null));
    expect(l, contains('iOS gave no reason code'));
  });

  for (final platform in ['Windows', 'Linux', 'web']) {
    test('$platform: not available, never "unknown"', () {
      final l = line(
        platform: platform,
        reports: false,
        reason: DisconnectReason(ErrorPlatform.fbp, null, null),
      );
      expect(l, contains('reason not available on $platform'));
      expect(l.toLowerCase(), isNot(contains('unknown')));
    });
  }

  test('time since the last frame and the app state', () {
    final l = line(secs: 261, lifecycle: AppLifecycleState.paused);
    expect(l, contains('last frame from the radio 261s ago'));
    expect(l, contains('app paused'));
  });

  test('no lifecycle state reported', () {
    final l = line(lifecycle: null);
    expect(l, contains('app state not reported'));
  });
}
