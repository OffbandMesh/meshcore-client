// Receiving a contact card (#610).
//
// Before this, an incoming <key:type:name> rendered as raw text while the stock
// app showed a native Add Contact button for the very same payload. Sharing
// worked outbound only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/widgets/translated_message_content.dart';

const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _card = '<$_key:1:Ka8sbi>';

class _Conn extends MeshCoreConnector {
  _Conn({this.known = const {}});

  /// Public key hexes already in contacts. Mirrors the connector's own
  /// `_knownContactKeys` set, which is what the chip now consults.
  final Set<String> known;

  @override
  bool isKnownContact(String publicKeyHex) => known.contains(publicKeyHex);
}

Future<void> _pump(WidgetTester tester, String text, _Conn conn) =>
    tester.pumpWidget(
      ChangeNotifierProvider<MeshCoreConnector>.value(
        value: conn,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TranslatedMessageContent(
              displayText: text,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('a received card renders as an actionable chip, not raw text', (
    tester,
  ) async {
    await _pump(tester, 'here is mine $_card', _Conn());

    // The raw payload must not be shown.
    expect(find.textContaining(_key), findsNothing);
    // An actionable affordance is offered instead.
    expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
    expect(find.byType(InkWell), findsOneWidget);
    // The caption survives alongside it.
    expect(find.textContaining('here is mine'), findsOneWidget);
  });

  testWidgets('a card for a known contact does not offer to re-add', (
    tester,
  ) async {
    // Mirrors stock, which warned rather than silently re-adding.
    await _pump(tester, _card, _Conn(known: {_key}));

    expect(find.byIcon(Icons.how_to_reg), findsOneWidget);
    expect(find.byIcon(Icons.person_add_alt_1), findsNothing);
    // Not tappable, so it cannot be double-added.
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a malformed card falls back to plain text rather than lying', (
    tester,
  ) async {
    // Right shape, impossible type. Rendering an Add chip here would promise
    // something the parser will refuse.
    const bad = '<$_key:9:Bob>';
    await _pump(tester, bad, _Conn());

    expect(find.byIcon(Icons.person_add_alt_1), findsNothing);
    expect(find.textContaining(bad), findsOneWidget);
  });

  testWidgets('a mention and a card in one message both render', (
    tester,
  ) async {
    // The two patterns are collected and sorted by position, so this is the
    // case that would break a naive single-regex implementation.
    await _pump(tester, '@[Bob] add this $_card', _Conn());

    expect(find.textContaining('@Bob'), findsOneWidget);
    expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
    expect(find.textContaining(_key), findsNothing);
  });

  testWidgets('a plain message is untouched and keeps link support', (
    tester,
  ) async {
    await _pump(tester, 'just a normal message', _Conn());

    expect(find.byIcon(Icons.person_add_alt_1), findsNothing);
    expect(find.textContaining('just a normal message'), findsOneWidget);
  });

  testWidgets('two cards in one message render as two separate chips', (
    tester,
  ) async {
    // Regression for the Gemini review: parsing from the first `<` to the last
    // `>` would have read this as one span running from the first key to the
    // second name, and produced garbage.
    const other =
        'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    await _pump(tester, '$_card and <$other:2:Bob>', _Conn());

    expect(find.byIcon(Icons.person_add_alt_1), findsNWidgets(2));
    expect(find.textContaining('Ka8sbi'), findsOneWidget);
    expect(find.textContaining('Bob'), findsOneWidget);
    expect(find.textContaining(_key), findsNothing);
  });

  testWidgets('a nested bracket mess yields one card, and it is the outer key', (
    tester,
  ) async {
    // Adversarial input from a public channel. `[^>]*` cannot cross a `>`, so
    // the match ends at the inner closing bracket and the nested text becomes
    // part of the OUTER card's name. Exactly one add is offered, for the outer
    // key, and the tap opens the dialog where the key is visible before
    // anything is written to the radio. No second key is silently smuggled in.
    const other =
        'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';
    await _pump(tester, '<$_key:1:Name <$other:2:Inner>>', _Conn());

    expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
    // The parser took the outer card, so the nested text is shown as the name
    // rather than being treated as a second identity.
    expect(find.textContaining('Name <'), findsOneWidget);
  });

  testWidgets('names with spaces and emoji survive into the chip label', (
    tester,
  ) async {
    await _pump(tester, '<$_key:2:Roger KY4RS 🧙>', _Conn());

    expect(find.textContaining('Roger KY4RS 🧙'), findsOneWidget);
    expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
  });
}
