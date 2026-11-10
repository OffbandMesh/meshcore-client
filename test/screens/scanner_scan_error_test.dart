// Pins #1033: a Bluetooth scan that cannot start must tell the user, and stay
// on screen until dismissed. On Android 11 and below the BLE plugin refuses
// to scan while system Location is off; the scanner used to log that and show
// nothing, so a user tapped Scan 172 times without learning why.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/screens/scanner_screen.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:provider/provider.dart';

/// The exact error `FlutterBluePlusPlugin.java:505-507` raises when Location
/// is off. Pinned here so a plugin change to the wording fails this test.
final _locationOff = PlatformException(
  code: 'startScan',
  message: 'Location services are required for Bluetooth scan',
);

class _ScanConnector extends MeshCoreConnector {
  Object? failWith;
  int startScanCalls = 0;

  @override
  MeshCoreConnectionState get state => MeshCoreConnectionState.disconnected;

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    startScanCalls++;
    final error = failWith;
    if (error != null) throw error;
  }
}

Future<AppLocalizations> _pumpScanner(
  WidgetTester tester,
  _ScanConnector connector,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<MeshCoreConnector>.value(value: connector),
        ChangeNotifierProvider<AppSettingsService>(
          create: (_) => AppSettingsService(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ScannerScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return AppLocalizations.of(tester.element(find.byType(ScannerScreen)));
}

Future<void> _tapScan(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(
    find.widgetWithText(FloatingActionButton, l10n.scanner_scan),
  );
  // Let the failure land, then finish the entrance animation, which is what
  // starts a non-persistent message's timeout.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Well past the 4 second default. Settle afterwards, or a timed-out message
/// is caught mid-exit, still found, and the check could never fail.
Future<void> _waitPastTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

/// Drain ScannerScreen's dispose-time disconnect before teardown.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('Location off: says so, and the message stays', (tester) async {
    final connector = _ScanConnector()..failWith = _locationOff;
    final l10n = await _pumpScanner(tester, connector);

    await _tapScan(tester, l10n);
    expect(connector.startScanCalls, 1);
    expect(find.text(l10n.scanner_scanFailedLocationOff), findsOneWidget);
    expect(find.text(l10n.scanner_scanFailedGeneric), findsNothing);

    await _waitPastTimeout(tester);
    expect(find.text(l10n.scanner_scanFailedLocationOff), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('any other scan failure: generic message, and it stays', (
    tester,
  ) async {
    final connector = _ScanConnector()
      ..failWith = PlatformException(code: 'startScan', message: 'adapter');
    final l10n = await _pumpScanner(tester, connector);

    await _tapScan(tester, l10n);
    expect(find.text(l10n.scanner_scanFailedGeneric), findsOneWidget);
    expect(find.text(l10n.scanner_scanFailedLocationOff), findsNothing);
    expect(find.textContaining('PlatformException'), findsNothing);

    await _waitPastTimeout(tester);
    expect(find.text(l10n.scanner_scanFailedGeneric), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a scan that starts shows neither message', (tester) async {
    final connector = _ScanConnector();
    final l10n = await _pumpScanner(tester, connector);

    await _tapScan(tester, l10n);
    expect(connector.startScanCalls, 1);
    expect(find.text(l10n.scanner_scanFailedLocationOff), findsNothing);
    expect(find.text(l10n.scanner_scanFailedGeneric), findsNothing);
    await _unmount(tester);
  });

  testWidgets('after a failure Scan is still pressable and tries again', (
    tester,
  ) async {
    final connector = _ScanConnector()..failWith = _locationOff;
    final l10n = await _pumpScanner(tester, connector);

    await _tapScan(tester, l10n);
    final scan = tester.widget<FloatingActionButton>(
      find.widgetWithText(FloatingActionButton, l10n.scanner_scan),
    );
    expect(scan.onPressed, isNotNull);

    await _tapScan(tester, l10n);
    expect(connector.startScanCalls, 2);
    expect(find.text(l10n.scanner_scanFailedLocationOff), findsOneWidget);
    await _unmount(tester);
  });
}
