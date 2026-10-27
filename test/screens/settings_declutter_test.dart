// Pins the #902 Settings declutter: config import/export, the GPX exports, and
// "Sync queued messages now" live under the Actions pane (they are user
// operations); the Debug pane keeps only diagnostics, with App Debug Logging
// ahead of Companion Debug. Positive (present under Actions) and negative
// (absent from Debug) assertions sit together so a row drifting back to the
// wrong pane fails CI.

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
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // Narrow layout: the category list renders and each detail pane builds
    // lazily when its tile is tapped (so unrelated panes never construct).
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
  }

  Future<void> openPane(WidgetTester tester, String categoryTitle) async {
    // The category list is built lazily, so a category below the fold does not
    // exist until scrolled to. #977 added Location, which pushed Debug past it.
    await tester.scrollUntilVisible(find.text(categoryTitle), 200);
    await tester.tap(find.text(categoryTitle));
    await tester.pumpAndSettle();
  }

  testWidgets('Actions holds the moved user-operations', (tester) async {
    await pumpSettings(tester);
    await openPane(tester, 'Actions');

    // Sync queued messages now (moved from Debug).
    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    // Config export + import (moved from Debug).
    expect(find.byIcon(Icons.save_alt), findsOneWidget);
    expect(find.byIcon(Icons.upload_file), findsOneWidget);
    // The three GPX exports (moved from Debug).
    expect(find.byIcon(Icons.download_outlined), findsNWidgets(3));
    // The pre-existing Actions still here.
    expect(find.byIcon(Icons.restart_alt), findsOneWidget); // reboot
  });

  testWidgets('Debug keeps only diagnostics, correctly ordered', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openPane(tester, 'Debug');

    // The moved user-operations are gone from Debug. save_alt + upload_file
    // are unique to the export card, so their absence proves the whole card
    // (config export/import AND the GPX rows) left the pane.
    expect(find.byIcon(Icons.sync_problem_outlined), findsNothing);
    expect(find.byIcon(Icons.save_alt), findsNothing);
    expect(find.byIcon(Icons.upload_file), findsNothing);

    // Serial capture stays (its leading icon is also download_outlined, which
    // is why the GPX absence above is asserted via save_alt, not that icon).
    expect(find.text('Serial capture'), findsOneWidget);
    // Mesh topology stays (useful diagnosing with a user).
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);

    // Full ordering per the owner's spec: App Debug Logging, then Companion
    // Debug, then App Debug (view log). Pinning all three guards against any
    // row drifting within the pane, not just the first pair.
    final loggingDy = tester
        .getTopLeft(find.byIcon(Icons.bug_report_outlined))
        .dy; // App Debug Logging toggle
    final companionDy = tester
        .getTopLeft(find.byIcon(Icons.bluetooth_outlined))
        .dy; // Companion Debug
    final appDebugDy = tester
        .getTopLeft(find.byIcon(Icons.code_outlined))
        .dy; // App Debug (view log)
    expect(loggingDy, lessThan(companionDy));
    expect(companionDy, lessThan(appDebugDy));
  });
}
