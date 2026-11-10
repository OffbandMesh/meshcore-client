// The iPhone-app-on-a-Mac notice (#1140): shown only for the iOS app running
// on a Mac, once per app version, with no link to another download.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/ios_on_mac_notice.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs() {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

/// One app launch. A button stands in for the gate's post-frame call.
Future<void> _launch(
  WidgetTester tester,
  SharedPreferences prefs, {
  bool isIOS = true,
  bool onMac = true,
  String version = '1.8.1+70',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => IosOnMacNotice.onLaunch(
              context,
              isIOS: isIOS,
              isOnMac: () async => onMac,
              prefs: prefs,
              installedVersion: () async => version,
            ),
            child: const Text('launch'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('launch'));
  await tester.pumpAndSettle();
}

final _title = find.text('iPhone app on a Mac');

Future<void> _dismiss(WidgetTester tester) async {
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the iOS app on a Mac shows it, with OK as its only button', (
    tester,
  ) async {
    await _launch(tester, await _prefs());
    expect(_title, findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget); // the test's own button
    expect(find.byType(FilledButton), findsOneWidget);
    await _dismiss(tester);
    expect(_title, findsNothing);
  });

  testWidgets('an iPhone or iPad never shows it', (tester) async {
    await _launch(tester, await _prefs(), onMac: false);
    expect(_title, findsNothing);
  });

  testWidgets('no other platform asks or shows it', (tester) async {
    var asked = false;
    final prefs = await _prefs();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => IosOnMacNotice.onLaunch(
              context,
              isIOS: false,
              isOnMac: () async => asked = true,
              prefs: prefs,
              installedVersion: () async => '1.8.1+70',
            ),
            child: const Text('launch'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('launch'));
    await tester.pumpAndSettle();
    expect(asked, isFalse);
    expect(_title, findsNothing);
  });

  testWidgets('asks the iOS app over offband/platform, isiOSAppOnMac', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('offband/platform'),
      (call) async {
        calls.add(call.method);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('offband/platform'),
        null,
      ),
    );
    final prefs = await _prefs();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => IosOnMacNotice.onLaunch(
              context,
              isIOS: true,
              prefs: prefs,
              installedVersion: () async => '1.8.1+70',
            ),
            child: const Text('launch'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('launch'));
    await tester.pumpAndSettle();
    expect(calls, ['isiOSAppOnMac']);
    expect(_title, findsOneWidget);
  });

  testWidgets('once per version: not again for the same one, again after an '
      'update', (tester) async {
    final prefs = await _prefs();
    await _launch(tester, prefs);
    await _dismiss(tester);
    await _launch(tester, prefs);
    expect(_title, findsNothing);
    await _launch(tester, prefs, version: '1.8.2+71');
    expect(_title, findsOneWidget);
  });
}
