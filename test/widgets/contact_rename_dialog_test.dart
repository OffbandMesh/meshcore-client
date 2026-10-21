// Custom Name override for contacts (#750), task 750.4: the rename UI.
//
// Tests T23, T24, T27, T28, T29 and T30 from the plan of record.
//
// T29 and T30 came out of the pre-PR adversarial review on the plan. T3 and T4
// prove the model's getter tolerates an empty custom name, but nothing proved
// the UI never writes one, and a working Clear button (T24) would have masked
// a broken Save path. They assert what reaches the connector, not what the
// screen shows, because that is where the wrong value would be stored.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/widgets/contact_rename_dialog.dart';
import 'package:provider/provider.dart';

const _received = 'KQ4EZN-Repeater';

Contact _contact({String? customName}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, 0x66)),
  receivedName: _received,
  customName: customName,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

/// Records what the dialog asked the connector to store, which is the thing
/// that matters: a wrong value here is persisted.
class _RecordingConnector extends MeshCoreConnector {
  final calls = <(String, String?)>[];

  @override
  Future<void> setContactCustomName(String contactKeyHex, String? name) async {
    calls.add((contactKeyHex, name));
  }
}

Future<void> _open(
  WidgetTester tester,
  _RecordingConnector connector,
  Contact contact,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: connector,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showContactRenameDialog(context, contact),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  late _RecordingConnector connector;

  setUp(() => connector = _RecordingConnector());

  testWidgets('T23 + saving a name sends it to the connector', (tester) async {
    await _open(tester, connector, _contact());

    await tester.enterText(find.byType(TextField), 'Chuck');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(connector.calls.single.$2, 'Chuck');
  });

  testWidgets('T23b + the field opens pre-filled with the current name', (
    tester,
  ) async {
    await _open(tester, connector, _contact(customName: 'Chuck'));

    expect(find.text('Chuck'), findsOneWidget);
  });

  testWidgets('T24 + Clear sends null, reverting to the received name', (
    tester,
  ) async {
    await _open(tester, connector, _contact(customName: 'Chuck'));

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(connector.calls.single.$2, isNull);
  });

  testWidgets('T29 - saving an EMPTY field never stores an empty string', (
    tester,
  ) async {
    // The review's finding. A plausible implementation saves '' here, the
    // display still looks right because the getter falls back, and the dialog
    // can never truly unset the name through its primary action.
    await _open(tester, connector, _contact(customName: 'Chuck'));

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      connector.calls.single.$2,
      isNull,
      reason:
          'an empty field must clear. Asserting null strictly rather than '
          'accepting an empty string, because an empty string IS the defect '
          'the review found: the display would look right while the stored '
          'value was wrong.',
    );
  });

  testWidgets('T30 - saving a WHITESPACE-ONLY field does the same', (
    tester,
  ) async {
    await _open(tester, connector, _contact(customName: 'Chuck'));

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(connector.calls.single.$2, isNull);
  });

  group('T25 and T26 the node name shows only when it differs', () {
    testWidgets('+ shown while the typed name differs from the node name', (
      tester,
    ) async {
      await _open(tester, connector, _contact(customName: 'Chuck'));

      expect(find.textContaining(_received), findsOneWidget);
    });

    testWidgets('- not shown when the typed name IS the node name', (
      tester,
    ) async {
      // Otherwise the same string appears twice for no reason.
      await _open(tester, connector, _contact(customName: _received));

      expect(find.textContaining('Node name:'), findsNothing);
    });
  });

  group('T27 the length message appears only when it should', () {
    testWidgets('- absent while the input is valid', (tester) async {
      await _open(tester, connector, _contact());

      await tester.enterText(find.byType(TextField), 'Chuck');
      await tester.pump();

      expect(find.textContaining('Keep it under'), findsNothing);
    });

    testWidgets('+ present once the input is too long', (tester) async {
      await _open(tester, connector, _contact());

      await tester.enterText(
        find.byType(TextField),
        'x' * (maxCustomNameLength + 1),
      );
      await tester.pump();

      expect(find.textContaining('Keep it under'), findsOneWidget);
    });

    testWidgets('- an over-length name cannot be saved at all', (tester) async {
      await _open(tester, connector, _contact());

      await tester.enterText(
        find.byType(TextField),
        'x' * (maxCustomNameLength + 1),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(connector.calls, isEmpty);
    });
  });

  testWidgets('T28 + a name of CJK and ZWJ emoji saves intact', (tester) async {
    // It never crosses the wire, so #636's grapheme truncation must not be
    // applied to it. Counted in characters, so this is well within the cap.
    const rich = '测试 🧙‍♂️ Chuck';
    await _open(tester, connector, _contact());

    await tester.enterText(find.byType(TextField), rich);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(connector.calls.single.$2, rich);
  });
}
