import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/services/stale_history_sweep.dart';
import 'package:meshcore_open/widgets/storage_reclaim_card.dart';

/// Epic B of #962, task B2.
///
/// Tests the CARD, not the sweep. The sweep's behaviour is pinned by Epic A's
/// 18 unit tests, which run under plain `test()`. It cannot be re-run here:
/// it uses `compute`, and an isolate deadlocks `pumpAndSettle` inside
/// `flutter_test`'s fake-async zone, which is what made the first version of
/// this file hang past ten minutes rather than fail. So the sweep is injected
/// and each outcome is fed in directly.
///
/// The case this task exists for is the third one: a key held back because its
/// rows could not be verified must be REPORTED, not merely logged. Owner
/// decision 2026-10-22.
void main() {
  StaleHistoryOutcome outcome({
    List<String> cleared = const [],
    List<String> refused = const [],
    int before = 70 * 1024 * 1024,
    int after = 70 * 1024 * 1024,
  }) => StaleHistoryOutcome(
    cleared: cleared,
    refused: refused,
    bytesBefore: before,
    bytesAfter: after,
  );

  Future<void> pump(
    WidgetTester tester, {
    required Future<StaleHistoryOutcome> Function() runSweep,
    Future<int> Function()? readSize,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StorageReclaimCard(
            runSweep: runSweep,
            readSize: readSize ?? () async => 70 * 1024 * 1024,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapClear(WidgetTester tester) async {
    await tester.tap(find.text('Clear Stale History Now'));
    await tester.pumpAndSettle();
  }

  testWidgets('it shows the database size before anything is clicked', (
    tester,
  ) async {
    await pump(tester, runSweep: () async => outcome());

    expect(find.textContaining('Message database:'), findsOneWidget);
    expect(find.textContaining('70.0 MB'), findsOneWidget);
  });

  testWidgets('nothing eligible reports nothing to clear', (tester) async {
    await pump(tester, runSweep: () async => outcome());

    await tapClear(tester);

    expect(find.text('Nothing to clear.'), findsOneWidget);
    expect(find.textContaining('Kept'), findsNothing);
  });

  testWidgets('cleared keys report the count and the size returned', (
    tester,
  ) async {
    await pump(
      tester,
      runSweep: () async => outcome(
        cleared: const ['a', 'b', 'c'],
        before: 70 * 1024 * 1024,
        after: 54 * 1024 * 1024,
      ),
    );

    await tapClear(tester);

    expect(find.textContaining('Cleared 3 old copies'), findsOneWidget);
    expect(find.textContaining('16.0 MB returned'), findsOneWidget);
    // And the size row updates to what the sweep actually left behind, rather
    // than still showing the pre-sweep number.
    expect(find.textContaining('Message database: 54.0 MB'), findsOneWidget);
  });

  testWidgets('a refused key is REPORTED, not just logged', (tester) async {
    await pump(
      tester,
      runSweep: () async => outcome(cleared: const ['a'], refused: const ['b']),
    );

    await tapClear(tester);

    expect(
      find.textContaining('Kept 1 that could not be verified'),
      findsOneWidget,
      reason: 'silence here is how #952 went unnoticed for days',
    );
    expect(
      find.textContaining('messages are intact'),
      findsOneWidget,
      reason:
          'it has to say the history is safe, not only that something was '
          'held back',
    );
    // Both halves are shown: what went and what did not.
    expect(find.textContaining('Cleared 1 old copies'), findsOneWidget);
  });

  testWidgets('refusals show even when nothing at all was cleared', (
    tester,
  ) async {
    await pump(tester, runSweep: () async => outcome(refused: const ['b']));

    await tapClear(tester);

    expect(find.text('Nothing to clear.'), findsOneWidget);
    expect(
      find.textContaining('Kept 1 that could not be verified'),
      findsOneWidget,
      reason:
          'a run that cleared nothing BECAUSE of a refusal is the most '
          'important case to surface, not the least',
    );
  });

  testWidgets('a failure says the messages are intact', (tester) async {
    // "Could not finish" on a delete action otherwise reads as "something was
    // half-deleted".
    await pump(tester, runSweep: () async => throw StateError('boom'));

    await tapClear(tester);

    expect(find.textContaining('Could not finish'), findsOneWidget);
    expect(find.textContaining('messages are intact'), findsOneWidget);
    expect(
      find.textContaining('may already have been cleared'),
      findsOneWidget,
      reason:
          'the sweep deletes per key, so a throw can follow real deletes and '
          'the message must not claim nothing happened (Gemini review)',
    );
  });

  testWidgets('a second tap in the same frame cannot start a second sweep', (
    tester,
  ) async {
    // The disabled button is not enough: setState only SCHEDULES a rebuild,
    // so two taps inside one frame both see a live onPressed. _clear guards
    // on _running for that, and two concurrent sweeps would mean two
    // concurrent VACUUMs.
    var runs = 0;
    final gate = Completer<StaleHistoryOutcome>();
    await pump(
      tester,
      runSweep: () {
        runs++;
        return gate.future;
      },
    );

    final button = find.text('Clear Stale History Now');
    await tester.tap(button, warnIfMissed: false);
    await tester.tap(button, warnIfMissed: false);

    expect(runs, 1, reason: 'the second tap in the same frame must be ignored');

    gate.complete(outcome());
    await tester.pumpAndSettle();
  });

  testWidgets('the button is disabled while it runs', (tester) async {
    final gate = Completer<StaleHistoryOutcome>();
    await pump(tester, runSweep: () => gate.future);

    await tester.tap(find.text('Clear Stale History Now'));
    await tester.pump();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
      reason: 'a second tap mid-sweep would run two VACUUMs at once',
    );
    expect(find.text('Clearing...'), findsOneWidget);

    gate.complete(outcome(cleared: const ['a']));
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
      reason: 'and it must come back, or the action works exactly once',
    );
  });

  testWidgets('an unreadable size leaves the row out rather than erroring', (
    tester,
  ) async {
    await pump(
      tester,
      runSweep: () async => outcome(),
      readSize: () async => throw StateError('no size'),
    );

    expect(find.textContaining('Message database:'), findsNothing);
    // The action is still usable: a size we cannot read is not a reason to
    // block clearing.
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}
