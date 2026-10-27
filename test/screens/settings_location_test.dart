// Pins #977: Location is a top-level Settings category directly under Radio
// Settings, and the only place GPS lives. Each placement is asserted from both
// sides (present in Location, absent from Node Settings) so a control drifting
// back fails CI. The writes the radio sees are pinned too: this was a move, not
// a behavior change, apart from coordinates and interval saving independently.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/native.dart';

/// Supplies custom vars and coordinates, and records every write so the
/// negative cases can prove nothing left the client.
class _SpyConnector extends MeshCoreConnector {
  Map<String, String>? vars;
  double? lat;
  double? lon;
  final List<String> customVarWrites = [];
  final List<(double, double)> locationWrites = [];

  @override
  Map<String, String>? get currentCustomVars => vars;

  @override
  double? get selfLatitude => lat;

  @override
  double? get selfLongitude => lon;

  @override
  Future<void> setCustomVar(String value) async {
    customVarWrites.add(value);
    final sep = value.indexOf(':');
    if (sep > 0) {
      (vars ??= <String, String>{})[value.substring(0, sep)] = value.substring(
        sep + 1,
      );
      notifyListeners();
    }
  }

  @override
  Future<void> setNodeLocation({
    required double lat,
    required double lon,
  }) async {
    locationWrites.add((lat, lon));
  }

  @override
  Future<void> refreshDeviceInfo() async {}
}

void main() {
  late OffbandDatabase db;
  late _SpyConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = _SpyConnector();
    connector.sendFrameOverrideForTest = (_) {};
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // Narrow layout: the category list renders and each pane is pushed.
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
          ChangeNotifierProvider<AppSettingsService>(
            create: (_) => AppSettingsService(),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openPane(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('Location sits directly under Radio Settings', (tester) async {
    await pumpSettings(tester);

    final radio = tester.getTopLeft(find.text('Radio Settings')).dy;
    final location = tester.getTopLeft(find.text('Location')).dy;
    final stats = tester.getTopLeft(find.text('Radio stats')).dy;
    expect(radio, lessThan(location));
    expect(location, lessThan(stats));
    expect(find.text('GPS, coordinates, and reporting'), findsOneWidget);
  });

  testWidgets('Node Settings no longer carries GPS or a Location row', (
    tester,
  ) async {
    // A GPS radio: before #977 this showed the toggle in Node Settings.
    connector.vars = {'gps': '1', 'gps_interval': '900'};
    await pumpSettings(tester);
    await openPane(tester, 'Node Settings');

    expect(find.text('GPS Enable'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('GPS coordinates'), findsNothing);
  });

  testWidgets('a GPS radio shows the toggle and the interval in Location', (
    tester,
  ) async {
    connector.vars = {'gps': '1', 'gps_interval': '900'};
    connector.lat = 39.103118;
    connector.lon = -84.51202;
    await pumpSettings(tester);
    await openPane(tester, 'Location');

    expect(find.text('GPS Enable'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isTrue);
    expect(find.text('39.103118, -84.512020'), findsOneWidget);
    expect(find.text('Every 15 minutes'), findsOneWidget);

    // The toggle writes the same custom var it always did.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(connector.customVarWrites, equals(['gps:0']));
  });

  testWidgets('a radio without GPS shows coordinates only', (tester) async {
    connector.vars = {};
    await pumpSettings(tester);
    await openPane(tester, 'Location');

    expect(find.text('Coordinates'), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text('GPS Enable'), findsNothing);
    expect(find.text('Position reporting interval'), findsNothing);
  });

  testWidgets('coordinates save on their own, without touching the interval', (
    tester,
  ) async {
    // No interval reported. In the old combined dialog an empty interval
    // returned early and skipped the coordinates; they must now save.
    connector.vars = {'gps': '1'};
    await pumpSettings(tester);
    await openPane(tester, 'Location');

    await tester.tap(find.text('Coordinates'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '39.5');
    await tester.enterText(fields.at(1), '-84.25');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(connector.locationWrites, equals([(39.5, -84.25)]));
    expect(connector.customVarWrites, isEmpty);
  });

  testWidgets('an out-of-range interval is refused and nothing is sent', (
    tester,
  ) async {
    connector.vars = {'gps': '1', 'gps_interval': '900'};
    await pumpSettings(tester);
    await openPane(tester, 'Location');

    await tester.tap(find.text('Position reporting interval'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '59');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(connector.customVarWrites, isEmpty);
    expect(
      find.text(
        'Interval must be at least 60 seconds, and less than 86400 seconds.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a valid interval writes the same custom var as before', (
    tester,
  ) async {
    connector.vars = {'gps': '1', 'gps_interval': '900'};
    await pumpSettings(tester);
    await openPane(tester, 'Location');

    await tester.tap(find.text('Position reporting interval'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '120');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(connector.customVarWrites, equals(['gps_interval:120']));
    expect(connector.locationWrites, isEmpty);
    expect(find.text('Every 2 minutes'), findsOneWidget);
  });
}
