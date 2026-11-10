// Pins #693: with no radio connected, the scanner reaches the app-level
// settings (Share logs, the log viewers, About) and nothing that needs the
// radio. Share logs must hand over the same on-disk log file the log screens
// export, and an export that cannot happen must say so until dismissed.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/scanner_screen.dart';
import 'package:meshcore_open/screens/settings/app_only_settings_screen.dart';
import 'package:meshcore_open/screens/settings_screen.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/file_log_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');
const _share = MethodChannel('dev.fluttercommunity.plus/share');

late Directory _supportDir;

/// Every share the app asked the OS for, as the paths it handed over.
final List<List<String>> _shared = [];

/// When set, the share sheet fails the way a platform error would.
bool _shareThrows = false;

Widget _app(MeshCoreConnector connector, Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
      ChangeNotifierProvider<AppSettingsService>(
        create: (_) => AppSettingsService(),
      ),
      ChangeNotifierProvider<AppDebugLogService>(
        create: (_) => AppDebugLogService(),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void _narrowView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

AppLocalizations _l10n(WidgetTester tester, Type screen) =>
    AppLocalizations.of(tester.element(find.byType(screen)));

/// From a scanner with no radio, open the settings gear.
Future<AppLocalizations> _openFromScanner(WidgetTester tester) async {
  _narrowView(tester);
  final connector = MeshCoreConnector();
  expect(connector.state, MeshCoreConnectionState.disconnected);
  await tester.pumpWidget(_app(connector, const ScannerScreen()));
  await tester.pumpAndSettle();
  final l10n = _l10n(tester, ScannerScreen);
  await tester.tap(find.byTooltip(l10n.settings_title));
  await tester.pumpAndSettle();
  expect(find.byType(AppOnlySettingsScreen), findsOneWidget);
  return l10n;
}

/// Tap Share in the real zone, where the export's file IO can run, then let
/// it progress frame by frame until [done] holds. The ceiling is generous so
/// a slow runner waits rather than flakes; a run that never gets there fails
/// on the caller's next expectation.
Future<void> _tapShareUntil(
  WidgetTester tester,
  String label,
  bool Function() done,
) async {
  await tester.runAsync(() => tester.tap(find.text(label)));
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

bool _shown(String text) => find.text(text).evaluate().isNotEmpty;

/// Drain ScannerScreen's dispose-time disconnect before teardown.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _supportDir = Directory.systemTemp.createTempSync('offband_693_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return _supportDir.path;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_share, (call) async {
      if (_shareThrows) {
        throw PlatformException(code: 'share_failed');
      }
      _shared.add(List<String>.from((call.arguments as Map)['paths'] as List));
      return 'dev.fluttercommunity.plus/share/success';
    });
    await FileLogService.instance.init();
  });

  tearDownAll(() async {
    await FileLogService.instance.dispose();
    if (_supportDir.existsSync()) _supportDir.deleteSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    PackageInfo.setMockInitialValues(
      appName: 'Offband MeshCore',
      packageName: 'app.offband.meshcore',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
    _shareThrows = false;
  });

  group('with no radio connected, the scanner', () {
    testWidgets('opens app-only settings: App Settings, Debug, About', (
      tester,
    ) async {
      final l10n = await _openFromScanner(tester);

      expect(find.text(l10n.settings_appSettings), findsOneWidget);
      expect(find.text(l10n.settings_debug), findsOneWidget);
      expect(find.text(l10n.settings_about), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      await _unmount(tester);
    });

    testWidgets('offers no category that needs the radio', (tester) async {
      final l10n = await _openFromScanner(tester);

      for (final deviceCategory in [
        l10n.settings_nodeSettings,
        l10n.settings_radioSettings,
        l10n.settings_location,
        l10n.radioStats_settingsTile,
        l10n.settings_privacy,
        l10n.contacts_title,
        l10n.block_settingsTitle,
        l10n.settings_messageSettings,
        'Observer',
        l10n.settings_deviceInfo,
        l10n.settings_actions,
        l10n.settings_experimental,
      ]) {
        expect(find.text(deviceCategory), findsNothing, reason: deviceCategory);
      }
      await _unmount(tester);
    });

    testWidgets('Debug has the log rows and none of the radio rows', (
      tester,
    ) async {
      final l10n = await _openFromScanner(tester);
      await tester.tap(find.text(l10n.settings_debug));
      await tester.pumpAndSettle();

      expect(find.text(l10n.debugLog_shareLog), findsOneWidget);
      expect(find.text(l10n.appSettings_appDebugLogging), findsOneWidget);
      expect(find.text(l10n.settings_companionDebugLog), findsOneWidget);
      expect(find.text(l10n.settings_appDebugLog), findsOneWidget);

      expect(find.text(l10n.deviceCli_title), findsNothing);
      expect(find.text('Serial capture'), findsNothing);
      expect(find.text('Mesh topology'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('About shows the app version', (tester) async {
      final l10n = await _openFromScanner(tester);
      await tester.tap(find.text(l10n.settings_about));
      await tester.pumpAndSettle();

      expect(find.text(l10n.settings_aboutVersion('9.9.9+99')), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('Share logs with no radio', () {
    testWidgets('hands the on-disk log file to the share sheet', (
      tester,
    ) async {
      const marker = 'issue-693 marker line';
      FileLogService.instance.write(marker);
      final l10n = await _openFromScanner(tester);
      await tester.tap(find.text(l10n.settings_debug));
      await tester.pumpAndSettle();

      final sharesBefore = _shared.length;
      await _tapShareUntil(
        tester,
        l10n.debugLog_shareLog,
        () => _shared.length > sharesBefore,
      );

      expect(_shared.length, sharesBefore + 1);
      final logDir = FileLogService.instance.logDir!.path;
      final handedOver = _shared.last;
      expect(handedOver, isNotEmpty);
      expect(handedOver.first, startsWith(logDir));
      final text = await tester.runAsync(
        () => File(handedOver.first).readAsString(),
      );
      expect(text, contains(marker));
      expect(find.text(l10n.debugLog_logUnavailable), findsNothing);
      expect(find.text(l10n.debugLog_exportFailed), findsNothing);
      await _unmount(tester);
    });

    testWidgets('a failing share says so, and the message stays', (
      tester,
    ) async {
      FileLogService.instance.write('issue-693 failing share');
      _shareThrows = true;
      final l10n = await _openFromScanner(tester);
      await tester.tap(find.text(l10n.settings_debug));
      await tester.pumpAndSettle();

      await _tapShareUntil(
        tester,
        l10n.debugLog_shareLog,
        () => _shown(l10n.debugLog_exportFailed),
      );
      // Finish the entrance animation, which is what starts the timeout.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(l10n.debugLog_exportFailed), findsOneWidget);

      // Well past the 4 second default: an error must wait to be dismissed.
      // Settle afterwards, or a timed-out message is caught mid-exit and
      // still found, and this check could never fail.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text(l10n.debugLog_exportFailed), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('no log on disk says so, and the message stays', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await FileLogService.instance.flushAndGetActiveFile();
        for (final f in FileLogService.instance.logDir!.listSync()) {
          f.deleteSync(recursive: true);
        }
      });
      final l10n = await _openFromScanner(tester);
      await tester.tap(find.text(l10n.settings_debug));
      await tester.pumpAndSettle();

      final sharesBefore = _shared.length;
      await _tapShareUntil(
        tester,
        l10n.debugLog_shareLog,
        () => _shown(l10n.debugLog_logUnavailable),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_shared.length, sharesBefore, reason: 'nothing to hand over');
      expect(find.text(l10n.debugLog_logUnavailable), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text(l10n.debugLog_logUnavailable), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('device Settings, connected, is unchanged by the split', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;

    setUp(() {
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

    testWidgets('keeps its device categories and its radio debug rows', (
      tester,
    ) async {
      _narrowView(tester);
      await tester.pumpWidget(_app(connector, const SettingsScreen()));
      await tester.pumpAndSettle();
      final l10n = _l10n(tester, SettingsScreen);

      for (final category in [
        l10n.settings_nodeSettings,
        l10n.settings_radioSettings,
        l10n.settings_deviceInfo,
        l10n.settings_actions,
        l10n.settings_debug,
        l10n.settings_about,
      ]) {
        await tester.scrollUntilVisible(find.text(category), 200);
        expect(find.text(category), findsOneWidget, reason: category);
      }

      await tester.tap(find.text(l10n.settings_debug));
      await tester.pumpAndSettle();
      for (final row in [
        l10n.debugLog_shareLog,
        l10n.appSettings_appDebugLogging,
        l10n.settings_companionDebugLog,
        l10n.settings_appDebugLog,
        'Serial capture',
        'Mesh topology',
      ]) {
        await tester.scrollUntilVisible(find.text(row), 200);
        expect(find.text(row), findsOneWidget, reason: row);
      }
    });
  });
}
