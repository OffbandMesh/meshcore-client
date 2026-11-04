import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/translated_message_content.dart';

Future<void> _pump(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TranslatedMessageContent(
          displayText: text,
          style: const TextStyle(fontSize: 14),
        ),
      ),
    ),
  );
}

void main() {
  group('TranslatedMessageContent mention rendering (#233)', () {
    testWidgets('inline mention renders as a chip, not literal', (
      tester,
    ) async {
      await _pump(tester, 'hey @[Bob] how are you');
      expect(find.text('@Bob'), findsOneWidget); // chip
      expect(find.textContaining('@[Bob]'), findsNothing); // no literal
    });

    testWidgets('leading mention renders as a chip', (tester) async {
      await _pump(tester, '@[Bob] hello');
      expect(find.text('@Bob'), findsOneWidget);
    });

    testWidgets('multiple mentions each render as chips', (tester) async {
      await _pump(tester, '@[Alice] and @[Bob]');
      expect(find.text('@Alice'), findsOneWidget);
      expect(find.text('@Bob'), findsOneWidget);
    });
  });

  group('TranslatedMessageContent links beside a mention (#1074)', () {
    const url = 'https://example.org';

    testWidgets('a link in a reply opens the confirm dialog', (tester) async {
      await _pump(tester, '@[Bob] $url');
      expect(find.text('@Bob'), findsOneWidget);

      await tester.tapOnText(find.textRange.ofSubstring(url));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(AlertDialog, url), findsOneWidget);
    });

    testWidgets('a link between two mentions opens the confirm dialog', (
      tester,
    ) async {
      await _pump(tester, '@[Alice] see $url @[Bob]');

      await tester.tapOnText(find.textRange.ofSubstring(url));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AlertDialog, url), findsOneWidget);
    });

    testWidgets('plain text beside a mention opens nothing', (tester) async {
      await _pump(tester, '@[Bob] no link here');

      await tester.tapOnText(find.textRange.ofSubstring('no link here'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('TranslatedMessageContent.leadingReplyName (#232)', () {
    test('extracts a space-terminated leading reply name', () {
      expect(TranslatedMessageContent.leadingReplyName('@[Bob] hi'), 'Bob');
      expect(
        TranslatedMessageContent.leadingReplyName('@[Bob Smith] g:x'),
        'Bob Smith',
      );
    });

    test('null when not leading or no trailing space', () {
      expect(TranslatedMessageContent.leadingReplyName('hi @[Bob]'), isNull);
      expect(TranslatedMessageContent.leadingReplyName('@[Bob]'), isNull);
      expect(TranslatedMessageContent.leadingReplyName('hello'), isNull);
    });
  });
}
