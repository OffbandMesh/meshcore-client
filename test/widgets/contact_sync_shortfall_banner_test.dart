import 'package:flutter/gestures.dart';
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
      find.textContaining(
        'reported 350 contacts; after checking again the app has 106',
      ),
      findsOneWidget,
    );
    expect(find.text('APP'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  // #764: contacts the radio answered "not found" for are named, and only
  // when there are any.
  group('confirmed gone', () {
    const withGone = ContactSyncShortfall(
      declared: 350,
      received: 340,
      keptLocally: 10,
      confirmedGone: 4,
    );

    testWidgets('banner names them when there are some', (tester) async {
      await tester.pumpWidget(build(shortfall: withGone));

      expect(
        find.textContaining('4 saved contacts are no longer on the radio.'),
        findsOneWidget,
      );
    });

    testWidgets('one reads in the singular', (tester) async {
      await tester.pumpWidget(
        build(
          shortfall: const ContactSyncShortfall(
            declared: 350,
            received: 349,
            keptLocally: 1,
            confirmedGone: 1,
          ),
        ),
      );

      expect(
        find.textContaining('1 saved contact is no longer on the radio.'),
        findsOneWidget,
      );
    });

    testWidgets('banner says nothing about it when there are none', (
      tester,
    ) async {
      await tester.pumpWidget(build(shortfall: short));

      expect(find.textContaining('no longer on the radio'), findsNothing);
    });

    testWidgets('the decision dialog names them too', (tester) async {
      await tester.pumpWidget(
        build(shortfall: withGone, decisionPending: true, undelivered: 10),
      );

      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(
            '4 saved contacts are no longer on the radio.',
          ),
        ),
        findsOneWidget,
      );
    });
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

  // #713: the app mounts the banner in MaterialApp.builder, above the
  // Navigator, where there is no Overlay. The tests above mount it under
  // `home:`, which has one, so they could not see this.
  group('mounted where the app mounts it (MaterialApp.builder)', () {
    Widget inBuilder({bool decisionPending = false}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => ContactSyncShortfallBanner(
        shortfall: short,
        decisionPending: decisionPending,
        undeliveredCount: 244,
        onDismiss: () => calls.add('dismiss'),
        onKeep: () => calls.add('keep'),
        onUseRadio: () => calls.add('useRadio'),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const Scaffold(body: Text('APP')),
    );

    testWidgets('hovering the close button does not break the app', (
      tester,
    ) async {
      await tester.pumpWidget(inBuilder());
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byIcon(Icons.close)));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('Contact sync incomplete'), findsOneWidget);
      expect(find.text('APP'), findsOneWidget);
    });

    testWidgets('the decision dialog works there too', (tester) async {
      await tester.pumpWidget(inBuilder(decisionPending: true));
      await tester.pump();
      await tester.tap(find.text('Keep my contacts'));

      expect(tester.takeException(), isNull);
      expect(calls, ['keep']);
    });
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
