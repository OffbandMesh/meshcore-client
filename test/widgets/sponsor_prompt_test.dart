// Sponsor window timing (#1129), owner's rules of 2026-11-09: first shown
// after 3 launches and 7 days, Not now sleeps 30 days, Sponsor 90 days, Never
// Show Again ends it, and test builds show it once per commit.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/widgets/sponsor_prompt.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _day0 = DateTime(2026, 11, 9, 12);

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// One app launch at [at]. A button stands in for the gate's post-frame call.
Future<void> _launch(
  WidgetTester tester,
  SharedPreferences prefs, {
  required DateTime at,
  String sha = '',
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
            onPressed: () => SponsorPrompt.onLaunch(
              context,
              sha: sha,
              isIOS: isIOS,
              prefs: prefs,
              clock: () => at,
              installedVersion: () async => version,
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

/// Launches twice on day 0, then once at [at]: the third launch.
Future<void> _thirdLaunchAt(
  WidgetTester tester,
  SharedPreferences prefs,
  DateTime at,
) async {
  await _launch(tester, prefs, at: _day0);
  await _launch(tester, prefs, at: _day0);
  await _launch(tester, prefs, at: at);
}

Future<void> _choose(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
}

final _title = find.text('Support Offband');
DateTime _days(int n) => _day0.add(Duration(days: n));

void main() {
  group('first show waits for 3 launches and 7 days', () {
    testWidgets('a fresh install never shows it on day 0', (tester) async {
      final prefs = await _prefs();
      for (var i = 0; i < 5; i++) {
        await _launch(tester, prefs, at: _day0);
        expect(_title, findsNothing);
      }
    });

    testWidgets('3 launches inside 7 days do not show it', (tester) async {
      final prefs = await _prefs();
      await _thirdLaunchAt(tester, prefs, _days(6));
      expect(_title, findsNothing);
    });

    testWidgets('7 days but only 2 launches do not show it', (tester) async {
      final prefs = await _prefs();
      await _launch(tester, prefs, at: _day0);
      await _launch(tester, prefs, at: _days(8));
      expect(_title, findsNothing);
    });

    testWidgets('the 3rd launch after 7 days shows it, with all choices', (
      tester,
    ) async {
      final prefs = await _prefs();
      await _thirdLaunchAt(tester, prefs, _days(7));
      expect(_title, findsOneWidget);
      expect(find.text('Sponsor'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Never Show Again'), findsOneWidget);
      expect(
        find.textContaining('anytime from About in Settings'),
        findsOneWidget,
      );
      // Saved while the window is still open, so a crash can't loop it.
      expect(
        prefs.getInt(SponsorPrompt.nextKey),
        _days(37).millisecondsSinceEpoch,
      );
    });
  });

  testWidgets('Not now sleeps 30 days', (tester) async {
    final prefs = await _prefs();
    await _thirdLaunchAt(tester, prefs, _days(7));
    await _choose(tester, 'Not now');

    await _launch(tester, prefs, at: _days(36));
    expect(_title, findsNothing);
    await _launch(tester, prefs, at: _days(37));
    expect(_title, findsOneWidget);
  });

  testWidgets('closing it without a choice counts as Not now', (tester) async {
    final prefs = await _prefs();
    await _thirdLaunchAt(tester, prefs, _days(7));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);

    await _launch(tester, prefs, at: _days(36));
    expect(_title, findsNothing);
    await _launch(tester, prefs, at: _days(37));
    expect(_title, findsOneWidget);
  });

  testWidgets('Sponsor opens the page and sleeps 90 days', (tester) async {
    final prefs = await _prefs();
    final opened = <Uri>[];
    Future<bool> open(Uri uri) async {
      opened.add(uri);
      return true;
    }

    await _launch(tester, prefs, at: _day0, open: open);
    await _launch(tester, prefs, at: _day0, open: open);
    await _launch(tester, prefs, at: _days(7), open: open);
    await _choose(tester, 'Sponsor');
    expect(opened, [Uri.parse('https://offband.org/donate')]);
    expect(find.text('Could not open the link'), findsNothing);

    await _launch(tester, prefs, at: _days(96));
    expect(_title, findsNothing);
    await _launch(tester, prefs, at: _days(97));
    expect(_title, findsOneWidget);
  });

  testWidgets('upgrades alone do not bring it back', (tester) async {
    final prefs = await _prefs();
    await _thirdLaunchAt(tester, prefs, _days(7));
    await _choose(tester, 'Not now');
    for (final version in ['1.8.1+70', '1.8.2+71', '1.9.0+72']) {
      await _launch(tester, prefs, at: _days(10), version: version);
      expect(_title, findsNothing);
    }
  });

  testWidgets('Never Show Again never returns', (tester) async {
    final prefs = await _prefs();
    await _thirdLaunchAt(tester, prefs, _days(7));
    await _choose(tester, 'Never Show Again');
    expect(prefs.getBool(SponsorPrompt.offKey), isTrue);
    for (final day in [40, 100, 400, 2000]) {
      await _launch(tester, prefs, at: _days(day), version: '9.0.0+999');
      expect(_title, findsNothing);
    }
  });

  testWidgets('iOS never shows it and records nothing', (tester) async {
    final prefs = await _prefs();
    await _launch(tester, prefs, at: _day0, isIOS: true);
    await _launch(tester, prefs, at: _day0, isIOS: true);
    await _launch(tester, prefs, at: _days(30), isIOS: true);
    expect(_title, findsNothing);
    expect(prefs.getInt(SponsorPrompt.launchesKey), isNull);
  });

  group('test builds', () {
    testWidgets('show it on the first launch, once per commit, no waits', (
      tester,
    ) async {
      final prefs = await _prefs();
      await _launch(tester, prefs, at: _day0, sha: 'abc1234');
      expect(_title, findsOneWidget);
      await _choose(tester, 'Not now');

      await _launch(tester, prefs, at: _day0, sha: 'abc1234');
      expect(_title, findsNothing);

      await _launch(tester, prefs, at: _day0, sha: 'def5678');
      expect(_title, findsOneWidget);
    });

    testWidgets('a new commit shows it even after Never Show Again', (
      tester,
    ) async {
      final prefs = await _prefs();
      await _launch(tester, prefs, at: _day0, sha: 'abc1234');
      await _choose(tester, 'Never Show Again');
      await _launch(tester, prefs, at: _day0, sha: 'def5678');
      expect(_title, findsOneWidget);
    });

    test('are known by version and commit, releases by version', () {
      expect(SponsorPrompt.buildId('1.8.0+69', sha: ''), '1.8.0+69');
      expect(
        SponsorPrompt.buildId('1.8.0+69', sha: 'abc1234'),
        '1.8.0+69@abc1234',
      );
    });
  });

  for (final failure in ['returns false', 'throws']) {
    testWidgets('a Sponsor link that $failure says so and the message stays', (
      tester,
    ) async {
      final prefs = await _prefs();
      Future<bool> open(Uri uri) async {
        if (failure == 'throws') throw Exception('no browser');
        return false;
      }

      await _launch(tester, prefs, at: _day0, sha: 'abc1234', open: open);
      await _choose(tester, 'Sponsor');
      expect(find.text('Could not open the link'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Could not open the link'), findsOneWidget);
    });
  }

  testWidgets('the first screen counts each launch through the gate', (
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
    expect(PrefsManager.instance.getInt(SponsorPrompt.launchesKey), 1);
    expect(
      PrefsManager.instance.getInt(SponsorPrompt.firstLaunchKey),
      isNotNull,
    );
    // A release build waits; a test build (GIT_SHA defined) shows at once.
    expect(
      _title,
      SponsorPrompt.buildSha.isEmpty ? findsNothing : findsOneWidget,
    );
  });
}
