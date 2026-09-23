import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/contact_sync_shortfall_banner.dart';

/// #674: a short contact sync must be loud and stay visible, and the choice
/// after a failed retry must default to keeping the saved contacts.
void main() {
  late List<String> calls;

  Widget build({
    ContactSyncShortfall? shortfall,
    bool decisionPending = false,
    int undelivered = 244,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ContactSyncShortfallBanner(
        shortfall: shortfall,
        decisionPending: decisionPending,
        undeliveredCount: undelivered,
        onDismiss: () => calls.add('dismiss'),
        onKeep: () => calls.add('keep'),
        onUseRadio: () => calls.add('useRadio'),
        child: const Text('APP'),
      ),
    ),
  );

  const short = ContactSyncShortfall(
    declared: 350,
    received: 106,
    keptLocally: 244,
  );

  setUp(() => calls = []);

  testWidgets('no shortfall: only the app renders', (tester) async {
    await tester.pumpWidget(build());

    expect(find.text('APP'), findsOneWidget);
    expect(find.text('Contact sync incomplete'), findsNothing);
  });

  testWidgets('shortfall: banner with the counts, above the app', (
    tester,
  ) async {
    await tester.pumpWidget(build(shortfall: short));

    expect(find.text('Contact sync incomplete'), findsOneWidget);
    expect(
      find.textContaining('reported 350 contacts but sent 106'),
      findsOneWidget,
    );
    expect(find.text('APP'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('no declared total uses its own wording', (tester) async {
    await tester.pumpWidget(
      build(
        shortfall: const ContactSyncShortfall(
          declared: null,
          received: 50,
          keptLocally: 3,
        ),
      ),
    );

    expect(find.textContaining('did not report how many'), findsOneWidget);
  });

  testWidgets('the close button dismisses', (tester) async {
    await tester.pumpWidget(build(shortfall: short));
    await tester.tap(find.byIcon(Icons.close));

    expect(calls, ['dismiss']);
  });

  group('decision pending', () {
    testWidgets('asks, says how many would be removed, defaults to Keep', (
      tester,
    ) async {
      await tester.pumpWidget(build(shortfall: short, decisionPending: true));
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('removes 244 contacts'), findsOneWidget);
      final keep = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(keep.autofocus, isTrue);
      expect(find.text('Keep my contacts'), findsOneWidget);
    });

    testWidgets('Keep my contacts', (tester) async {
      await tester.pumpWidget(build(shortfall: short, decisionPending: true));
      await tester.tap(find.text('Keep my contacts'));

      expect(calls, ['keep']);
    });

    testWidgets('Use the radio\'s list', (tester) async {
      await tester.pumpWidget(build(shortfall: short, decisionPending: true));
      await tester.tap(find.text('Use the radio\'s list'));

      expect(calls, ['useRadio']);
    });

    testWidgets('Enter on the dialog picks the default, Keep', (tester) async {
      await tester.pumpWidget(build(shortfall: short, decisionPending: true));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(calls, ['keep']);
    });
  });
}
