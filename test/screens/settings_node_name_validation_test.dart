// #885: the Settings node-name dialog mirrors the firmware's `set name`
// character rejection. An invalid name shows an inline error and the dialog
// stays open (the name is not sent); a clean name saves and the dialog closes.

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

/// Records any setNodeName the dialog would send, so the negative case can
/// prove nothing left the client.
class _SpyConnector extends MeshCoreConnector {
  final List<String> names = [];

  @override
  Future<void> setNodeName(String name) async {
    names.add(name);
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
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> openNameDialog(WidgetTester tester) async {
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
    await tester.tap(find.text('Node Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node Name'));
    await tester.pumpAndSettle();
  }

  testWidgets('a forbidden character blocks the save and shows an error', (
    tester,
  ) async {
    await openNameDialog(tester);

    await tester.enterText(find.byType(TextField), 'Base:Camp');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining("can't contain"), findsOneWidget);
    expect(find.text('Save'), findsOneWidget); // dialog still open
    expect(connector.names, isEmpty); // nothing sent
  });

  testWidgets('a clean name saves and closes the dialog', (tester) async {
    await openNameDialog(tester);

    await tester.enterText(find.byType(TextField), 'BaseCamp');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Save'), findsNothing); // dialog closed
    expect(connector.names, ['BaseCamp']);
  });
}
