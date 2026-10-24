// Pins #978: button actions live under Node Settings on caps byte 2 0x02, the
// buzzer under Message Settings on 0x01, and each opens only its own half.
// All four combinations are covered, because boards with a buzzer and no
// button exist (m5stack_unit_c6l, thinknode_m9, wio-tracker-l1-eink).

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Radio extends MeshCoreConnector {
  _Radio({required this.button, required this.buzzer});
  final bool button;
  final bool buzzer;
  final List<String> requests = [];

  @override
  bool get supportsButtonMatrix => button;

  @override
  bool get supportsNotifyScope => buzzer;

  // Values already read, so no screen sits on an animating spinner.
  @override
  ButtonMatrix? get buttonMatrix =>
      const ButtonMatrix(assignments: {}, supportedActions: 0);

  @override
  DeviceNotifyScope? get deviceNotifyScope => DeviceNotifyScope.all;

  @override
  Future<void> requestButtonMatrix() async => requests.add('matrix');

  @override
  Future<void> requestNotifyScope() async => requests.add('scope');
}

void main() {
  late OffbandDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> pumpSettings(WidgetTester tester, _Radio radio) async {
    radio.sendFrameOverrideForTest = (_) {};
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
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(find.text(text), 200);
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }

  /// What Node Settings and Message Settings each offer for this radio.
  Future<(bool, bool)> entries(WidgetTester tester, _Radio radio) async {
    await pumpSettings(tester, radio);
    await tapText(tester, 'Node Settings');
    final hasButton = find.text('Button actions').evaluate().isNotEmpty;
    await back(tester);
    await tapText(tester, 'Message Settings');
    final hasBuzzer = find.text('Buzzer and tones').evaluate().isNotEmpty;
    return (hasButton, hasBuzzer);
  }

  testWidgets('button only: an entry in Node Settings, none for a buzzer', (
    tester,
  ) async {
    final r = await entries(tester, _Radio(button: true, buzzer: false));
    expect(r, equals((true, false)));
  });

  testWidgets('buzzer only: an entry in Message Settings, none for a button', (
    tester,
  ) async {
    final r = await entries(tester, _Radio(button: false, buzzer: true));
    expect(r, equals((false, true)));
  });

  testWidgets('both: each in its own place', (tester) async {
    final r = await entries(tester, _Radio(button: true, buzzer: true));
    expect(r, equals((true, true)));
  });

  testWidgets('neither: no entry anywhere', (tester) async {
    final r = await entries(tester, _Radio(button: false, buzzer: false));
    expect(r, equals((false, false)));
  });

  testWidgets('the combined Button and buzzer entry is gone', (tester) async {
    await pumpSettings(tester, _Radio(button: true, buzzer: true));
    await tapText(tester, 'Node Settings');
    expect(find.text('Button and buzzer'), findsNothing);
  });

  testWidgets('Buzzer and tones opens only the buzzer half', (tester) async {
    final radio = _Radio(button: true, buzzer: true);
    await pumpSettings(tester, radio);
    await tapText(tester, 'Message Settings');
    await tapText(tester, 'Buzzer and tones');

    expect(find.text('Device notification scope'), findsOneWidget);
    // A button row: present whenever the button half renders.
    expect(find.text('Single press'), findsNothing);
    expect(radio.requests, equals(['scope']));
  });

  testWidgets('Button actions opens only the button half', (tester) async {
    final radio = _Radio(button: true, buzzer: true);
    await pumpSettings(tester, radio);
    await tapText(tester, 'Node Settings');
    await tapText(tester, 'Button actions');

    expect(find.text('Single press'), findsOneWidget);
    expect(find.text('Device notification scope'), findsNothing);
    expect(radio.requests, equals(['matrix']));
  });
}
