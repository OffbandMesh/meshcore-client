// Widget tests for the MQTT brokers screen (#80): a tile per broker, the + FAB
// opens the editor on the next empty slot, and long-press exposes the
// Enable/Disable/Edit/Clear actions (Clear behind a confirm). A toggle/save now
// verifies the device actually applied the change before confirming (#89).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/observer_config.dart';
import 'package:meshcore_open/screens/settings/mqtt_brokers_screen.dart';
import 'package:meshcore_open/services/observer_config_service.dart';

class _DummyConn extends MeshCoreConnector {}

class _FakeSvc extends ObserverConfigService {
  _FakeSvc(this._brokers) : super(_DummyConn());

  final List<BrokerConfig> _brokers;
  final List<String> setCalls = [];
  final List<int> clearCalls = [];
  bool toggleOk = true;
  String? errorText;

  /// When false, the device ACKs an enabled-SET but the verify re-read reports
  /// the slot UNCHANGED — models the HV4 ack-but-doesn't-apply bug (#89).
  bool deviceApplies = true;
  final Map<int, bool> _enabledOverride = {};

  @override
  String? get lastError => errorText;
  @override
  ObserverConfig? get config => ObserverConfig(brokers: _brokers);
  @override
  Future<List<BrokerConfig>?> getBrokers() async => _brokers;
  @override
  Future<bool> setBrokerField(int slot, String field, String value) async {
    setCalls.add('$slot.$field=$value');
    if (toggleOk && deviceApplies && field == 'enabled') {
      _enabledOverride[slot] = value == '1';
    }
    return toggleOk;
  }

  @override
  Future<BrokerConfig?> getBroker(int slot) async {
    final base = _brokers.firstWhere(
      (b) => b.slot == slot,
      orElse: () => BrokerConfig(slot: slot),
    );
    return base.copyWith(enabled: _enabledOverride[slot] ?? base.enabled);
  }

  @override
  Future<bool> clearBroker(int slot) async {
    clearCalls.add(slot);
    return true;
  }
}

Future<void> _pump(WidgetTester tester, _FakeSvc fake) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<ObserverConfigService>.value(
      value: fake,
      child: const MaterialApp(home: MqttBrokersScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a tile per broker', (tester) async {
    await _pump(
      tester,
      _FakeSvc(const [
        BrokerConfig(slot: 0, url: 'a.example', port: 1883, enabled: true),
        BrokerConfig(slot: 1, url: 'b.example', port: 8883),
      ]),
    );

    expect(find.text('[0] a.example'), findsOneWidget);
    expect(find.text('[1] b.example'), findsOneWidget);
  });

  testWidgets('the + FAB opens the editor on the next empty slot', (
    tester,
  ) async {
    await _pump(
      tester,
      _FakeSvc(const [BrokerConfig(slot: 0, url: 'a', port: 1883)]),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Editor app bar for the next empty slot (1).
    expect(find.text('Broker 1'), findsOneWidget);
  });

  testWidgets('long-press opens the action menu; Clear confirms then clears', (
    tester,
  ) async {
    final fake = _FakeSvc(const [
      BrokerConfig(slot: 2, url: 'a', port: 1883, enabled: true),
    ]);
    await _pump(tester, fake);

    await tester.longPress(find.text('[2] a'));
    await tester.pumpAndSettle();
    expect(find.text('Disable'), findsOneWidget); // enabled slot -> Disable
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear broker 2?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(fake.clearCalls, contains(2));
  });

  testWidgets('a successful quick Enable verifies then confirms', (
    tester,
  ) async {
    final fake = _FakeSvc(const [BrokerConfig(slot: 2, url: 'a', port: 1883)]);
    await _pump(tester, fake);

    await tester.longPress(find.text('[2] a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    // Advance past the settle delay so the verify re-read runs.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(fake.setCalls, contains('2.enabled=1'));
    expect(find.textContaining('Broker 2 enabled'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an ACK-but-not-applied toggle warns of a firmware issue', (
    tester,
  ) async {
    final fake = _FakeSvc(const [BrokerConfig(slot: 2, url: 'a', port: 1883)])
      ..deviceApplies = false; // ACKs success but re-read stays disabled
    await _pump(tester, fake);

    await tester.longPress(find.text('[2] a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(fake.setCalls, contains('2.enabled=1'));
    expect(find.textContaining('possible firmware issue'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failed quick toggle surfaces the device reason', (
    tester,
  ) async {
    final fake =
        _FakeSvc(const [
            BrokerConfig(slot: 2, url: 'a', port: 1883, enabled: true),
          ])
          ..toggleOk = false
          ..errorText = 'ERROR broker busy';
    await _pump(tester, fake);

    await tester.longPress(find.text('[2] a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ERROR broker busy'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });
}
