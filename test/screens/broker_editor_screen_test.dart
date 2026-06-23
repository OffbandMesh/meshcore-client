// Widget tests for the broker editor (#80).
//
// Pins the save contract the firmware depends on: only CHANGED fields go on the
// wire, a blank password keeps the stored one (write-only), `enable`/`wasLive`
// are derived from the slot, and a predictably-invalid value never reaches the
// device. Refresh re-reads the single slot and reseeds the form.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/observer_config.dart';
import 'package:meshcore_open/screens/settings/broker_editor_screen.dart';
import 'package:meshcore_open/services/observer_config_service.dart';

class _DummyConn extends MeshCoreConnector {}

class _SaveCall {
  _SaveCall(this.slot, this.fields, this.enable, this.wasLive);
  final int slot;
  final Map<String, String> fields;
  final bool enable;
  final bool wasLive;
}

class _FakeSvc extends ObserverConfigService {
  _FakeSvc() : super(_DummyConn());

  final List<_SaveCall> saveCalls = [];
  BrokerSaveResult result = const BrokerSaveResult.ok();
  BrokerConfig? fresh;

  @override
  Future<BrokerSaveResult> saveBroker(
    int slot, {
    required Map<String, String> fields,
    required bool enable,
    required bool wasLive,
  }) async {
    saveCalls.add(_SaveCall(slot, Map.of(fields), enable, wasLive));
    return result;
  }

  @override
  Future<BrokerConfig?> getBroker(int slot) async => fresh;
}

// Push the editor as a second route so its pop-on-success has somewhere to go.
Future<void> _open(
  WidgetTester tester,
  _FakeSvc fake,
  BrokerConfig broker,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<ObserverConfigService>.value(
      value: fake,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BrokerEditorScreen(broker: broker),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _drainSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('saves only changed fields; enable/wasLive come from the slot', (
    tester,
  ) async {
    final fake = _FakeSvc();
    await _open(
      tester,
      fake,
      const BrokerConfig(slot: 2, url: 'old', port: 1883, enabled: true),
    );

    await tester.enterText(find.byKey(const Key('broker_url')), 'newhost');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(fake.saveCalls, hasLength(1));
    final c = fake.saveCalls.single;
    expect(c.slot, 2);
    expect(c.fields['url'], 'newhost');
    expect(
      c.fields.containsKey('port'),
      isFalse,
      reason: 'an unchanged field must not be re-sent',
    );
    expect(c.wasLive, isTrue, reason: 'the slot was enabled on the device');
    expect(c.enable, isTrue);
    await _drainSnack(tester);
  });

  testWidgets('an out-of-range port blocks the save (never reaches the wire)', (
    tester,
  ) async {
    final fake = _FakeSvc();
    await _open(
      tester,
      fake,
      const BrokerConfig(slot: 1, url: 'h', port: 1883, enabled: true),
    );

    await tester.enterText(find.byKey(const Key('broker_port')), '99999');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(fake.saveCalls, isEmpty);
    expect(find.textContaining('Port must be'), findsOneWidget);
    await _drainSnack(tester);
  });

  testWidgets('a blank password is never sent (write-only keep)', (
    tester,
  ) async {
    final fake = _FakeSvc();
    await _open(
      tester,
      fake,
      const BrokerConfig(
        slot: 0,
        url: 'h',
        port: 1883,
        authType: BrokerAuthType.basic,
        passwordSet: true,
      ),
    );

    await tester.enterText(find.byKey(const Key('broker_username')), 'newuser');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    final c = fake.saveCalls.single;
    expect(c.fields['username'], 'newuser');
    expect(
      c.fields.containsKey('password'),
      isFalse,
      reason: 'a blank password field keeps the stored secret',
    );
    await _drainSnack(tester);
  });

  testWidgets('Refresh re-reads the slot and reseeds the form', (tester) async {
    final fake = _FakeSvc()
      ..fresh = const BrokerConfig(slot: 3, url: 'fromdevice', port: 8883);
    await _open(
      tester,
      fake,
      const BrokerConfig(slot: 3, url: 'stale', port: 1883),
    );

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('fromdevice'), findsOneWidget);
    expect(find.text('8883'), findsOneWidget);
  });

  testWidgets('disabling a slot saves even with incomplete fields', (
    tester,
  ) async {
    final fake = _FakeSvc();
    await _open(
      tester,
      fake,
      const BrokerConfig(
        slot: 2,
        url: 'h',
        port: 1883,
        enabled: true,
        authType: BrokerAuthType.jwt, // blank audience/owner
      ),
    );

    await tester.tap(find.byType(SwitchListTile)); // toggle enabled OFF
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(
      fake.saveCalls,
      hasLength(1),
      reason: 'disabling must not be blocked by field validation',
    );
    expect(fake.saveCalls.single.enable, isFalse);
    await _drainSnack(tester);
  });

  testWidgets('a JWT broker with blank owner/audience still enables', (
    tester,
  ) async {
    final fake = _FakeSvc();
    await _open(
      tester,
      fake,
      const BrokerConfig(
        slot: 2,
        url: 'h',
        port: 1883,
        authType:
            BrokerAuthType.jwt, // blank owner/audience -> firmware default
      ),
    );

    await tester.tap(find.byType(SwitchListTile)); // toggle enabled ON
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();

    expect(
      fake.saveCalls,
      hasLength(1),
      reason:
          'the client no longer gates JWT fields — the firmware enforces them '
          'with its defaults (owner -> device pubkey)',
    );
    expect(fake.saveCalls.single.enable, isTrue);
    await _drainSnack(tester);
  });
}
