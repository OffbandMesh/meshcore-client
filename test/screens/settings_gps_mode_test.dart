// Pins #969 on the Location screen, against the approved mockups (cards 1 to
// 4, docs/initiatives/standalone/975-settings-restructure/): one Off / On /
// Power save control, Power save offered only where ps_ok says the build can
// run it, one status row naming backed off, and a sleep row that exists only
// in Power save and treats 0 as the firmware default.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/offband_gps_status.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A radio that speaks the 0xC5 GPS sub-codes, with its state set directly.
class _GpsRadio extends MeshCoreConnector {
  GpsModeState? gpsState;
  String? error;
  DeviceUiSurface? errorSurface;
  final List<(GpsMode, int?)> writes = [];

  @override
  bool get supportsGpsMode => true;

  @override
  bool get supportsOffbandGps => false;

  @override
  GpsModeState? get gpsModeState => gpsState;

  @override
  String? get deviceUiError => error;

  @override
  DeviceUiSurface? get deviceUiErrorSurface => errorSurface;

  @override
  Map<String, String>? get currentCustomVars => {'gps': '1'};

  @override
  Future<void> requestGpsMode() async {}

  @override
  Future<OffbandGpsStatus?> requestOffbandGps({
    Duration timeout = const Duration(seconds: 5),
  }) async => null;

  @override
  Future<void> setGpsMode(GpsMode mode, {int? intervalSeconds}) async {
    writes.add((mode, intervalSeconds));
  }

  @override
  void clearDeviceUiError() {
    error = null;
    errorSurface = null;
    notifyListeners();
  }
}

GpsModeState gps({
  GpsMode mode = GpsMode.on,
  bool psOk = true,
  GpsActivity? activity = GpsActivity.on,
  int interval = 0,
  int wait = 0,
}) => GpsModeState(
  mode: mode,
  storedMode: mode.code,
  powerSaveAvailable: psOk,
  activity: activity,
  intervalSeconds: interval,
  waitSeconds: wait,
);

void main() {
  late OffbandDatabase db;
  late _GpsRadio radio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    radio = _GpsRadio();
    radio.sendFrameOverrideForTest = (_) {};
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  /// [settle] false is for a pane showing an indeterminate spinner, which
  /// animates forever and so never lets `pumpAndSettle` finish.
  Future<void> openLocation(WidgetTester tester, {bool settle = true}) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MeshCoreConnector>.value(value: radio),
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
    await tester.tap(find.text('Location'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // One frame to push the route, then enough time for its transition.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  }

  Finder segment(String label) => find.descendant(
    of: find.byType(SegmentedButton<GpsMode>),
    matching: find.text(label),
  );

  testWidgets('one control with three states replaces the toggle', (
    tester,
  ) async {
    radio.gpsState = gps();
    await openLocation(tester);

    expect(segment('Off'), findsOneWidget);
    expect(segment('On'), findsOneWidget);
    expect(segment('Power save'), findsOneWidget);
    // The legacy two-control layout is gone on a 0x20 radio.
    expect(find.text('GPS Enable'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('Power save is absent where the build cannot run it', (
    tester,
  ) async {
    radio.gpsState = gps(psOk: false);
    await openLocation(tester);

    expect(segment('Off'), findsOneWidget);
    expect(segment('On'), findsOneWidget);
    expect(segment('Power save'), findsNothing);
  });

  testWidgets('each choice writes its mode and leaves the interval alone', (
    tester,
  ) async {
    radio.gpsState = gps();
    await openLocation(tester);

    await tester.tap(segment('Power save'));
    await tester.pumpAndSettle();
    await tester.tap(segment('Off'));
    await tester.pumpAndSettle();

    // No explicit interval: the connector resends the radio's own.
    expect(
      radio.writes,
      equals([(GpsMode.powerSave, null), (GpsMode.off, null)]),
    );
  });

  testWidgets('backed off is named, with the wait to the next try', (
    tester,
  ) async {
    radio.gpsState = gps(
      mode: GpsMode.powerSave,
      activity: GpsActivity.backedOff,
      wait: 2880,
    );
    await openLocation(tester);

    expect(find.text('Backed off'), findsOneWidget);
    expect(find.text('Next try in 48 min'), findsOneWidget);
  });

  testWidgets('Off says what is shown instead of a fix', (tester) async {
    radio.gpsState = gps(mode: GpsMode.off, activity: GpsActivity.off);
    await openLocation(tester);

    expect(find.text('GPS is off'), findsOneWidget);
    expect(find.text('Showing the last stored position'), findsOneWidget);
  });

  testWidgets('the sleep row exists only in Power save', (tester) async {
    radio.gpsState = gps(mode: GpsMode.on);
    await openLocation(tester);
    expect(find.text('Sleep between fix attempts'), findsNothing);
  });

  testWidgets('a sleep of 0 reads as the firmware default, not a number', (
    tester,
  ) async {
    radio.gpsState = gps(mode: GpsMode.powerSave, interval: 0);
    await openLocation(tester);

    expect(find.text('Sleep between fix attempts'), findsOneWidget);
    expect(find.text('Firmware default, minimum 5 minutes'), findsOneWidget);
  });

  testWidgets('the stored sleep is shown, as the radio reported it', (
    tester,
  ) async {
    radio.gpsState = gps(mode: GpsMode.powerSave, interval: 300);
    await openLocation(tester);
    expect(find.text('Every 5 minutes'), findsOneWidget);
  });

  testWidgets('the sleep editor sends what was typed, including 0', (
    tester,
  ) async {
    radio.gpsState = gps(mode: GpsMode.powerSave, interval: 3600);
    await openLocation(tester);

    await tester.tap(find.text('Sleep between fix attempts'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(radio.writes, equals([(GpsMode.powerSave, 0)]));
  });

  testWidgets('a negative or non-numeric sleep is refused, nothing sent', (
    tester,
  ) async {
    radio.gpsState = gps(mode: GpsMode.powerSave, interval: 3600);
    await openLocation(tester);

    for (final bad in ['-5', 'abc']) {
      await tester.tap(find.text('Sleep between fix attempts'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), bad);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final message = find.text('Enter a whole number of seconds, 0 or more.');
      expect(message, findsOneWidget, reason: 'input "$bad"');
      // Persistent: still there after the default 4-second toast would end.
      await tester.pump(const Duration(seconds: 6));
      expect(message, findsOneWidget, reason: 'input "$bad" after 6 s');
      await tester.tap(message);
      await tester.pumpAndSettle();
    }
    expect(radio.writes, isEmpty);
  });

  testWidgets('a GPS refusal is held on the card until dismissed', (
    tester,
  ) async {
    radio.gpsState = gps();
    radio.error = 'This radio cannot run Power save';
    radio.errorSurface = DeviceUiSurface.gpsMode;
    await openLocation(tester);

    expect(find.text('This radio cannot run Power save'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('This radio cannot run Power save'), findsNothing);
  });

  testWidgets('another screen\'s refusal is not shown on Location', (
    tester,
  ) async {
    radio.gpsState = gps();
    radio.error = 'This radio has no buzzer';
    radio.errorSurface = DeviceUiSurface.notifyScope;
    await openLocation(tester);

    expect(find.text('This radio has no buzzer'), findsNothing);
  });

  testWidgets('before the first reply the card says it is reading', (
    tester,
  ) async {
    radio.gpsState = null;
    await openLocation(tester, settle: false);

    expect(find.text('Reading GPS settings…'), findsOneWidget);
    expect(find.byType(SegmentedButton<GpsMode>), findsNothing);
  });
}
