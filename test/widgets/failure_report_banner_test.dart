import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/send_logs_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/failure_monitor.dart';
import 'package:meshcore_open/services/log_upload_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/failure_report_banner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUploader extends LogUploader {
  _FakeUploader(this.result);
  final LogUploadResult result;
  final List<String?> notes = [];

  @override
  Future<LogUploadResult> send(
    Uint8List package, {
    required String platform,
    required String appVersion,
    String? note,
  }) async {
    notes.add(note);
    return result;
  }
}

Future<FailureMonitor> _monitorAfter(Object? foreground) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    FailureMonitor.markerKey,
    jsonEncode({'foreground': foreground, 'dartError': false}),
  );
  return FailureMonitor(prefs: prefs)..start(installHandlers: false);
}

Future<AppLocalizations> _pump(
  WidgetTester tester,
  FailureMonitor monitor,
  AppSettingsService settings, {
  LogUploader? uploader,
}) async {
  final nav = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MeshCoreConnector>.value(
          value: MeshCoreConnector(),
        ),
        ChangeNotifierProvider<AppSettingsService>.value(value: settings),
      ],
      child: MaterialApp(
        navigatorKey: nav,
        scaffoldMessengerKey: messenger,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => FailureReportBanner(
          monitor: monitor,
          navigatorKey: nav,
          messengerKey: messenger,
          uploader: uploader,
          zipPackage: (_) async => Uint8List.fromList([1, 2, 3]),
          child: child!,
        ),
        home: const Scaffold(body: Text('home')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.text('home')));
}

void main() {
  late AppSettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    settings = AppSettingsService();
    await settings.loadSettings();
  });

  testWidgets('offers to send after an unexpected exit; Not now hides it', (
    tester,
  ) async {
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings);

    expect(find.text(l10n.failureOffer_exited), findsOneWidget);
    expect(find.text(l10n.failureOffer_body), findsOneWidget);
    await tester.tap(find.text(l10n.failureOffer_notNow));
    await tester.pumpAndSettle();
    expect(find.text(l10n.failureOffer_exited), findsNothing);
    expect(monitor.pending, isNull);
    expect(settings.settings.crashLogsAsk, isTrue);
  });

  testWidgets('Send opens the Send to Offband screen', (tester) async {
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings);
    await tester.tap(find.widgetWithText(FilledButton, l10n.sendLogs_send));
    // The screen starts gathering real files, which never finishes inside the
    // test's fake clock, so pump frames rather than wait for it to settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SendLogsScreen), findsOneWidget);
    expect(monitor.pending, isNull);
  });

  testWidgets("Don't ask again turns the offer off", (tester) async {
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings);
    await tester.tap(find.text(l10n.failureOffer_dontAsk));
    await tester.pumpAndSettle();
    expect(settings.settings.crashLogsAsk, isFalse);

    final next = await _monitorAfter(true);
    await _pump(tester, next, settings);
    expect(find.text(l10n.failureOffer_exited), findsNothing);
  });

  testWidgets('a crash reported after start shows the crash wording', (
    tester,
  ) async {
    final monitor = await _monitorAfter(false);
    final l10n = await _pump(tester, monitor, settings);
    expect(find.text(l10n.failureOffer_body), findsNothing);
    monitor.recordExitReasons(['ANR'], backfill: false);
    await tester.pumpAndSettle();
    expect(find.text(l10n.failureOffer_anr), findsOneWidget);
  });

  testWidgets('with auto-send on, a crash is sent without asking', (
    tester,
  ) async {
    await settings.setCrashLogsAutoSend(true);
    final uploader = _FakeUploader(const LogUploadSent('OB-7K2QX'));
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings, uploader: uploader);

    expect(uploader.notes.single, contains('foregroundExit'));
    expect(find.text(l10n.failureOffer_body), findsNothing);
    expect(find.text(l10n.failureOffer_autoSent('OB-7K2QX')), findsOneWidget);
    expect(monitor.pending, isNull);
  });

  testWidgets('auto-send that fails falls back to asking', (tester) async {
    await settings.setCrashLogsAutoSend(true);
    final uploader = _FakeUploader(
      const LogUploadFailed(LogUploadFailure.network, 'offline'),
    );
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings, uploader: uploader);
    expect(uploader.notes, hasLength(1));
    expect(find.text(l10n.failureOffer_body), findsOneWidget);
  });

  testWidgets('an exit that cannot be placed is asked about, never auto-sent', (
    tester,
  ) async {
    await settings.setCrashLogsAutoSend(true);
    final uploader = _FakeUploader(const LogUploadSent('OB-7K2QX'));
    final monitor = await _monitorAfter(null);
    final l10n = await _pump(tester, monitor, settings, uploader: uploader);
    expect(uploader.notes, isEmpty);
    expect(find.text(l10n.failureOffer_exited), findsOneWidget);
  });

  testWidgets('turning auto-send on while the offer is showing sends it', (
    tester,
  ) async {
    final uploader = _FakeUploader(const LogUploadSent('OB-7K2QX'));
    final monitor = await _monitorAfter(true);
    final l10n = await _pump(tester, monitor, settings, uploader: uploader);
    expect(find.text(l10n.failureOffer_body), findsOneWidget);
    await settings.setCrashLogsAutoSend(true);
    await tester.pumpAndSettle();
    expect(uploader.notes, hasLength(1));
    expect(find.text(l10n.failureOffer_body), findsNothing);
  });

  testWidgets('auto-send is off unless the user turns it on', (tester) async {
    expect(settings.settings.crashLogsAutoSend, isFalse);
    final uploader = _FakeUploader(const LogUploadSent('OB-7K2QX'));
    final monitor = await _monitorAfter(true);
    await _pump(tester, monitor, settings, uploader: uploader);
    expect(uploader.notes, isEmpty);
  });
}
