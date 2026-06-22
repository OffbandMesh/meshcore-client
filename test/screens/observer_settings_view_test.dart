// Widget tests for the Observer settings pane (#64 U1).
//
// Security-sensitive UI behavior is pinned here: secrets are write-only and
// staged (a blank password keeps the stored one; an entered one is sent then
// cleared), saves send ONLY changed keys, an unexpected device value is
// normalized before it round-trips back, and every failure is surfaced
// (SAFELANE §6).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/observer_config.dart';
import 'package:meshcore_open/screens/settings/observer_settings_view.dart';
import 'package:meshcore_open/services/observer_config_service.dart';

class _DummyConn extends MeshCoreConnector {}

class _FakeSvc extends ObserverConfigService {
  _FakeSvc(
    this._cfg, {
    this.staleFlag = false,
    this.errorText,
    this.brokersDown = false,
  }) : super(_DummyConn());

  final ObserverConfig _cfg;
  final bool staleFlag;
  final String? errorText;
  final bool brokersDown;
  final List<MapEntry<String, String>> sets = [];

  @override
  bool get brokersUnavailable => brokersDown;
  @override
  bool get supported => true;
  @override
  ObserverConfig? get config => _cfg;
  @override
  bool get stale => staleFlag;
  @override
  String? get lastError => errorText;
  @override
  Future<void> refresh() async {}
  @override
  Future<bool> setFlat(String key, String value) async {
    sets.add(MapEntry(key, value));
    return true;
  }
}

ObserverConfig _cfg({String ssid = 'MyNet', int rotation = 0}) =>
    ObserverConfig(
      wifi: WifiConfig(
        ssid: ssid,
        enabled: true,
        status: WifiStatus.staConnected,
        ip: '10.0.0.5',
      ),
      mqtt: const MqttGlobalConfig(iata: 'HAO', statusInterval: 60),
      brokers: const [],
      display: DisplayConfig(rotation: rotation),
    );

Future<void> _pump(WidgetTester tester, _FakeSvc fake) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<ObserverConfigService>.value(
      value: fake,
      child: const MaterialApp(home: Scaffold(body: ObserverSettingsView())),
    ),
  );
  await tester.pumpAndSettle();
}

// Tap Save, run the staged sets, then drain the SnackBar's auto-dismiss timer
// so the test ends with no pending timers.
Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('save sends only changed keys; blank password is never sent', (
    tester,
  ) async {
    final fake = _FakeSvc(_cfg(ssid: 'MyNet'));
    await _pump(tester, fake);

    await tester.enterText(find.byKey(const Key('observer_ssid')), 'NewNet');
    // password left blank -> keep the stored one
    await _save(tester);

    final keys = fake.sets.map((e) => e.key).toList();
    expect(keys, contains('wifi.ssid'));
    expect(keys, isNot(contains('wifi.pwd')));
    expect(fake.sets.firstWhere((e) => e.key == 'wifi.ssid').value, 'NewNet');
  });

  testWidgets('entered password is sent as wifi.pwd, then the field clears', (
    tester,
  ) async {
    final fake = _FakeSvc(_cfg());
    await _pump(tester, fake);

    await tester.enterText(find.byKey(const Key('observer_pwd')), 'hunter2');
    await _save(tester);

    final pwd = fake.sets.where((e) => e.key == 'wifi.pwd').toList();
    expect(pwd, hasLength(1));
    expect(pwd.single.value, 'hunter2');
    final field = tester.widget<TextField>(
      find.byKey(const Key('observer_pwd')),
    );
    expect(field.controller!.text, isEmpty);
  });

  testWidgets(
    'an unexpected device rotation is normalized, never echoed back',
    (tester) async {
      final fake = _FakeSvc(_cfg(rotation: 90));
      await _pump(tester, fake);
      expect(tester.takeException(), isNull);

      await _save(tester);

      final rot = fake.sets.where((e) => e.key == 'display.rotation').toList();
      expect(rot, hasLength(1));
      expect(rot.single.value, '0'); // normalized to a valid segment, not '90'
    },
  );

  testWidgets('stale + error are surfaced (SAFELANE §6)', (tester) async {
    final fake = _FakeSvc(
      _cfg(),
      staleFlag: true,
      errorText: 'GET wifi.ssid failed',
    );
    await _pump(tester, fake);

    expect(find.textContaining('last read'), findsOneWidget);
    expect(find.text('GET wifi.ssid failed'), findsOneWidget);
  });

  testWidgets('an out-of-range status interval is not sent (#78 MINOR-B)', (
    tester,
  ) async {
    final fake = _FakeSvc(_cfg());
    await _pump(tester, fake);

    await tester.enterText(find.byKey(const Key('observer_interval')), '5');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle(); // _save runs; the SnackBar is still showing

    expect(
      fake.sets.where((e) => e.key == 'mqtt.status_interval'),
      isEmpty,
      reason: 'a value below the firmware range must not be put on the wire',
    );
    expect(find.textContaining('Status interval must be'), findsOneWidget);

    // drain the SnackBar's auto-dismiss timer for a clean test end
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('an in-range status interval is sent (#78 MINOR-B)', (
    tester,
  ) async {
    final fake = _FakeSvc(_cfg());
    await _pump(tester, fake);

    await tester.enterText(find.byKey(const Key('observer_interval')), '120');
    await _save(tester);

    final iv = fake.sets.where((e) => e.key == 'mqtt.status_interval').toList();
    expect(iv, hasLength(1));
    expect(iv.single.value, '120');
  });

  testWidgets('broker pool shows unavailable when the dump failed (#79)', (
    tester,
  ) async {
    final fake = _FakeSvc(_cfg(), brokersDown: true);
    await _pump(tester, fake);

    // The broker section is at the bottom of the scroll view; scroll it in.
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Broker pool unavailable'), findsOneWidget);
  });
}
