import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/radio_preset_service.dart';
import 'package:meshcore_open/widgets/radio_preset_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

RadioPreset preset(String title, String region, RadioPresetSource source) =>
    RadioPreset(
      id: '${source.name}:$title',
      title: title,
      region: region,
      frequencyMHz: 910.525,
      bandwidth: LoRaBandwidth.bw62_5,
      spreadingFactor: LoRaSpreadingFactor.sf7,
      codingRate: LoRaCodingRate.cr4_5,
      source: source,
    );

/// Menu rows only exist while the menu is open; the closed button shows
/// titles from selectedItemBuilder instead.
Finder menuItems({required bool enabled}) => find.byWidgetPredicate(
  (w) => w is DropdownMenuItem<String> && w.enabled == enabled,
);

void main() {
  late RadioPresetService service;
  final presets = [
    preset('Australia', 'Australia', RadioPresetSource.meshcore),
    preset('USA', 'USA', RadioPresetSource.meshcore),
    preset('USA - Philly Mesh', 'USA', RadioPresetSource.offband),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    service = RadioPresetService(
      prefs: await SharedPreferences.getInstance(),
      loadAsset: (_) async => throw StateError('no assets in this test'),
      fetch: (_) async => throw StateError('offline'),
    );
  });

  Future<List<RadioPreset>> pump(
    WidgetTester tester, {
    String? selectedId,
  }) async {
    final picked = <RadioPreset>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ListenableBuilder(
              listenable: service,
              builder: (context, _) => RadioPresetPicker(
                service: service,
                presets: presets,
                selectedId: selectedId,
                onSelected: picked.add,
              ),
            ),
          ),
        ),
      ),
    );
    return picked;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
  }

  testWidgets('groups presets under region headers with source labels (#729)', (
    tester,
  ) async {
    await pump(tester);
    await openMenu(tester);

    // One non-selectable header per region, one selectable row per preset.
    expect(menuItems(enabled: false), findsNWidgets(2));
    expect(menuItems(enabled: true), findsNWidgets(3));
    expect(find.text('MeshCore'), findsNWidgets(2));
    expect(find.text('Offband'), findsOneWidget);
  });

  testWidgets('selecting an entry reports it; a region header does nothing', (
    tester,
  ) async {
    final picked = await pump(tester);
    await openMenu(tester);

    await tester.tap(menuItems(enabled: false).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);

    // The menu may have closed on the header tap; reopen it if so.
    if (menuItems(enabled: true).evaluate().isEmpty) {
      await openMenu(tester);
    }
    await tester.tap(find.text('USA - Philly Mesh').last);
    await tester.pumpAndSettle();
    expect(picked.single.id, 'offband:USA - Philly Mesh');
  });

  testWidgets('starts on the selected preset', (tester) async {
    await pump(tester, selectedId: 'offband:USA - Philly Mesh');
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(field.initialValue, 'offband:USA - Philly Mesh');
  });

  testWidgets('an unknown selection shows no preset rather than failing', (
    tester,
  ) async {
    await pump(tester, selectedId: 'offband:gone');
    final field = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(field.initialValue, isNull);
  });

  testWidgets('a good refresh shows no error (#748)', (tester) async {
    final files = {
      for (final f in [kUpstreamPresetFile, kOverlayPresetFile])
        f: File('$kRadioPresetAssetDir$f').readAsStringSync(),
    };
    service = RadioPresetService(
      prefs: await SharedPreferences.getInstance(),
      loadAsset: (_) async => throw StateError('no assets in this test'),
      fetch: (url) async => files[url.split('/').last]!,
    );
    await pump(tester);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(service.refreshError, isNull);
    expect(find.textContaining('Presets updated'), findsOneWidget);
    expect(
      find.text("Couldn't update presets. Showing the saved list."),
      findsNothing,
    );
  });

  testWidgets('a failed refresh stays on screen as an error', (tester) async {
    await pump(tester);
    expect(
      find.text('Presets included with this version of the app'),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't update presets. Showing the saved list."),
      findsOneWidget,
    );
  });
}
