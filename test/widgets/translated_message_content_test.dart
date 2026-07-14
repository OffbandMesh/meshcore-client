import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/translated_message_content.dart';

Future<void> _pump(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
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
}
