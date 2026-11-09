// Sponsor prompt on the first launch after an install or upgrade (#1129).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/sponsor_prompt.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// Launches the app's first screen once: a button stands in for the scanner's
/// post-frame call.
Future<void> _launch(
  WidgetTester tester,
  SharedPreferences prefs, {
  String version = '1.8.0+69',
  bool isIOS = false,
  Future<bool> Function(Uri)? open,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => SponsorPrompt.maybeShow(
              context,
              version: version,
              isIOS: isIOS,
              prefs: prefs,
              open: open,
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

final _title = find.text('Support Offband');

void main() {
  testWidgets('a fresh install shows it, with all three choices', (
    tester,
  ) async {
    final prefs = await _prefs();
    await _launch(tester, prefs);
    expect(_title, findsOneWidget);
    expect(find.text('Sponsor'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text("Don't show again"), findsOneWidget);
    // Saved while the window is still open, so a crash can't loop it.
    expect(prefs.getString(SponsorPrompt.shownForKey), '1.8.0+69');
  });

  testWidgets('the same version does not show it again', (tester) async {
    final prefs = await _prefs({SponsorPrompt.shownForKey: '1.8.0+69'});
    await _launch(tester, prefs);
    expect(_title, findsNothing);
  });

  testWidgets('an upgrade shows it once more', (tester) async {
    final prefs = await _prefs({SponsorPrompt.shownForKey: '1.7.0+68'});
    await _launch(tester, prefs);
    expect(_title, findsOneWidget);
    expect(prefs.getString(SponsorPrompt.shownForKey), '1.8.0+69');
  });

  testWidgets('Not now closes it and the next upgrade asks again', (
    tester,
  ) async {
    final prefs = await _prefs();
    await _launch(tester, prefs);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
    expect(prefs.getBool(SponsorPrompt.offKey), isNull);

    await _launch(tester, prefs, version: '1.8.1+70');
    expect(_title, findsOneWidget);
  });

  testWidgets("Don't show again sticks across upgrades", (tester) async {
    final prefs = await _prefs();
    await _launch(tester, prefs);
    await tester.tap(find.text("Don't show again"));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
    expect(prefs.getBool(SponsorPrompt.offKey), isTrue);

    await _launch(tester, prefs, version: '1.9.0+71');
    expect(_title, findsNothing);
  });

  testWidgets('iOS never shows it and records nothing', (tester) async {
    final prefs = await _prefs();
    await _launch(tester, prefs, isIOS: true);
    expect(_title, findsNothing);
    expect(prefs.getString(SponsorPrompt.shownForKey), isNull);
  });

  testWidgets('the first screen offers it on its own after it draws', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    addTearDown(PrefsManager.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Offband MeshCore',
      packageName: 'app.offband.meshcore',
      version: '1.8.0',
      buildNumber: '69',
      buildSignature: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SponsorPromptGate(child: Scaffold(body: Text('scanner'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(_title, findsOneWidget);
    // Carries the commit when the test run passes --dart-define=GIT_SHA.
    expect(
      PrefsManager.instance.getString(SponsorPrompt.shownForKey),
      SponsorPrompt.buildId('1.8.0+69'),
    );
  });

  testWidgets('Sponsor opens the donate page and says nothing more', (
    tester,
  ) async {
    final prefs = await _prefs();
    final opened = <Uri>[];
    await _launch(
      tester,
      prefs,
      open: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    await tester.tap(find.text('Sponsor'));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
    expect(opened, [SponsorPrompt.sponsorUri]);
    expect(find.text('Could not open the link'), findsNothing);
    expect(prefs.getBool(SponsorPrompt.offKey), isNull);
  });

  for (final failure in ['returns false', 'throws']) {
    testWidgets('a Sponsor link that $failure says so and the message stays', (
      tester,
    ) async {
      final prefs = await _prefs();
      await _launch(
        tester,
        prefs,
        open: (uri) async {
          if (failure == 'throws') throw Exception('no browser');
          return false;
        },
      );
      await tester.tap(find.text('Sponsor'));
      await tester.pumpAndSettle();
      expect(find.text('Could not open the link'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Could not open the link'), findsOneWidget);
    });
  }

  test('a test build is known by its commit, a release by its version', () {
    expect(SponsorPrompt.buildId('1.8.0+69', sha: ''), '1.8.0+69');
    expect(
      SponsorPrompt.buildId('1.8.0+69', sha: 'abc1234'),
      '1.8.0+69@abc1234',
    );
  });

  testWidgets('two test builds of one version each show it once', (
    tester,
  ) async {
    final prefs = await _prefs();
    final first = SponsorPrompt.buildId('1.8.0+69', sha: 'abc1234');
    final second = SponsorPrompt.buildId('1.8.0+69', sha: 'def5678');
    await _launch(tester, prefs, version: first);
    expect(_title, findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    await _launch(tester, prefs, version: first);
    expect(_title, findsNothing);

    await _launch(tester, prefs, version: second);
    expect(_title, findsOneWidget);
  });

  test('Sponsor opens the donate page the About screen uses', () {
    expect(SponsorPrompt.sponsorUri.toString(), 'https://offband.org/donate');
  });
}
