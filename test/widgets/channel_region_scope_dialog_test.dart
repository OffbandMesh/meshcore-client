// Epic #815 T C2: channel Set Region Scope picker dialog.
// Decoupled from the connector (plain data + callbacks + injected service),
// so it widget-tests without a radio.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/region_discovery_service.dart';
import 'package:meshcore_open/widgets/channel_region_scope_dialog.dart';

void main() {
  final repeaters = [RepeaterChoice(name: 'rpt-01', pubKey: Uint8List(32))];
  RegionsReply reply(List<String> names) =>
      RegionsReply(tag: 1, clock: 1, regionNames: names);

  Future<void> pump(
    WidgetTester tester, {
    String? current,
    required RegionDiscoveryService service,
    required void Function(String?) onSave,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ChannelRegionScopeDialog(
            channelName: 'general',
            currentScope: current,
            repeaters: repeaters,
            service: service,
            onSave: (r) async => onSave(r),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('discover, pick a region, save returns it', (tester) async {
    String? result;
    var called = false;
    await pump(
      tester,
      service: RegionDiscoveryService((_, _) async => reply(['oki', 'test'])),
      onSave: (r) {
        called = true;
        result = r;
      },
    );
    await tester.tap(find.byKey(const Key('regionScopeDiscover')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('oki'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('regionScopeSave')));
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(result, 'oki');
  });

  testWidgets('selecting None saves null (clears the scope)', (tester) async {
    String? result = 'sentinel';
    await pump(
      tester,
      current: 'oki',
      service: RegionDiscoveryService((_, _) async => reply(['oki'])),
      onSave: (r) => result = r,
    );
    await tester.tap(find.byKey(const Key('regionScopeNone')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('regionScopeSave')));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
