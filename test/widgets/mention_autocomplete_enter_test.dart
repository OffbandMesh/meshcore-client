import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/mention_autocomplete.dart';

void main() {
  testWidgets('Enter inserts the highlighted emoji, not literal text (#231)', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionAutocompleteField(
            maxBytes: 200,
            controller: controller,
            focusNode: focusNode,
            // Ambiguous query: ':shr' matches both, so the pre-#231 code would
            // have sent the literal ':shr' instead of the highlighted glyph.
            emojiShortcodes: const {
              'shrug': '\u{1F937}',
              'shrimp': '\u{1F990}',
            },
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    controller.value = const TextEditingValue(
      text: ':shr',
      selection: TextSelection.collapsed(offset: 4),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text.contains(':shr'), isFalse);
    expect(
      controller.text.contains('\u{1F937}') ||
          controller.text.contains('\u{1F990}'),
      isTrue,
    );
  });

  testWidgets('Enter inserts the highlighted mention (#231)', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(() {
      controller.dispose();
      focusNode.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MentionAutocompleteField(
            maxBytes: 200,
            controller: controller,
            focusNode: focusNode,
            candidates: const [MentionCandidate(name: 'Bob', recent: false)],
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    controller.value = const TextEditingValue(
      text: '@Bo',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, contains('@[Bob]'));
  });
}
