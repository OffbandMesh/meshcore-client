// Pins the #884 Device CLI entry gate: a "Device CLI" row appears at the TOP of
// the Debug pane only when the classifier places the connected radio at stock
// v14+ (allowsCliFrame). It is absent when disconnected, on a stock-legacy
// radio, and on an Offband device (which gains the frame-66 CLI only at the
// upstream-1.18 absorb). Tapping it opens the console.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/device_cli_screen.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A RESP_CODE_DEVICE_INFO frame with the version string at its real offset.
Uint8List deviceInfo({
  required int length,
  required int verCode,
  required String version,
}) {
  final v = ascii.encode(version);
  assert(
    60 + v.length <= length,
    'version string does not fit in a $length-byte frame',
  );
  final f = Uint8List(length);
  f[0] = 13; // RESP_CODE_DEVICE_INFO
  f[1] = verCode;
  f.setRange(60, 60 + v.length, v);
  return f;
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (_) {};
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pumpAndOpenDebug(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
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
    // The category list is built lazily, so a category below the fold does not
    // exist until scrolled to. #977 added Location, which pushed Debug past it.
    await tester.scrollUntilVisible(find.text('Debug'), 200);
    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();
  }

  testWidgets('stock 1.18 radio: Device CLI row shows at the top of Debug', (
    tester,
  ) async {
    connector.handleFrameForTest(
      deviceInfo(length: 82, verCode: 14, version: 'v1.18.0'),
    );
    await pumpAndOpenDebug(tester);

    expect(find.text('Device CLI'), findsOneWidget);
    // Sits above App Debug Logging (the row that is otherwise first).
    final cliDy = tester.getTopLeft(find.byIcon(Icons.terminal)).dy;
    final loggingDy = tester
        .getTopLeft(find.byIcon(Icons.bug_report_outlined))
        .dy;
    expect(cliDy, lessThan(loggingDy));
  });

  testWidgets('tapping the row opens the console', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 82, verCode: 14, version: 'v1.18.0'),
    );
    await pumpAndOpenDebug(tester);

    await tester.tap(find.text('Device CLI'));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceCliScreen), findsOneWidget);
  });

  testWidgets('disconnected / no device info: no Device CLI row', (
    tester,
  ) async {
    // No device-info frame fed, so classification stays null.
    await pumpAndOpenDebug(tester);
    expect(find.text('Device CLI'), findsNothing);
    expect(find.byIcon(Icons.terminal), findsNothing);
  });

  testWidgets('stock-legacy radio (ver 13): no Device CLI row', (tester) async {
    connector.handleFrameForTest(
      deviceInfo(length: 82, verCode: 13, version: 'v1.17.1'),
    );
    await pumpAndOpenDebug(tester);
    expect(find.text('Device CLI'), findsNothing);
  });

  testWidgets('Offband radio: no Device CLI row (CLI arrives at the absorb)', (
    tester,
  ) async {
    connector.handleFrameForTest(
      deviceInfo(length: 85, verCode: 22, version: '1.4.0-1.17.0'),
    );
    await pumpAndOpenDebug(tester);
    expect(find.text('Device CLI'), findsNothing);
  });
}
