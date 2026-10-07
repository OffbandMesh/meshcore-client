// Epic #814 T B2: Discover Regions screen state rendering.
// Injects a fake discoverer service so each state renders without a radio.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/discover_regions_screen.dart';
import 'package:meshcore_open/services/region_discovery_service.dart';

Contact _repeater() => Contact(
  publicKey: Uint8List(32),
  name: 'rpt-01',
  type: advTypeRepeater,
  pathLength: 0,
  path: Uint8List(0),
  lastSeen: DateTime(2026),
);

Future<void> _pump(WidgetTester tester, RegionDiscoveryService svc) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: DiscoverRegionsScreen(repeater: _repeater(), service: svc),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  RegionsReply reply(List<String> names) =>
      RegionsReply(tag: 1, clock: 1, regionNames: names);

  testWidgets('success lists region names', (tester) async {
    await _pump(
      tester,
      RegionDiscoveryService((_, _) async => reply(['oki', 'test'])),
    );
    expect(find.text('oki'), findsOneWidget);
    expect(find.text('test'), findsOneWidget);
  });

  testWidgets('empty reply shows the empty state', (tester) async {
    await _pump(tester, RegionDiscoveryService((_, _) async => reply([])));
    expect(find.byKey(const Key('discoverRegionsEmpty')), findsOneWidget);
  });

  testWidgets('timeout shows the timeout state with a retry', (tester) async {
    await _pump(tester, RegionDiscoveryService((_, _) async => null));
    expect(find.byKey(const Key('discoverRegionsTimeout')), findsOneWidget);
    expect(find.byKey(const Key('discoverRegionsRetry')), findsOneWidget);
  });

  testWidgets('a thrown error shows the error state', (tester) async {
    await _pump(
      tester,
      RegionDiscoveryService((_, _) async => throw StateError('boom')),
    );
    expect(find.byKey(const Key('discoverRegionsError')), findsOneWidget);
  });
}
