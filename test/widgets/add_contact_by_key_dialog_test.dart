// Widget tests for manual key entry (#628).
//
// The point of this dialog is that it must produce exactly the same contact
// stub a scanned QR would, so these pin what actually reaches the connector:
// the key, the typed name, the chosen type, and the epoch lastSeen that keeps
// the firmware advert replay guard from muting the contact (#620).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/widgets/add_contact_by_key_dialog.dart';

const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

class _CapturingConn extends MeshCoreConnector {
  final List<Contact> added = [];

  @override
  Future<bool> addContactByKey(Contact stub) async {
    added.add(stub);
    return true;
  }
}

Future<void> _open(WidgetTester tester, _CapturingConn conn) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: conn,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAddContactByKeyDialog(context),
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
  testWidgets('a valid key produces an unverified stub with the typed name', (
    tester,
  ) async {
    final conn = _CapturingConn();
    await _open(tester, conn);

    await tester.enterText(find.byType(TextField).first, _key);
    await tester.enterText(find.byType(TextField).last, 'Ka8sbi');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(conn.added, hasLength(1));
    final stub = conn.added.single;
    expect(stub.publicKeyHex, _key);
    expect(stub.name, 'Ka8sbi');
    expect(stub.type, advTypeChat);
    // The reason this whole path exists. Anything else here and the contact
    // goes permanently deaf to its own adverts.
    expect(stub.lastSeen, DateTime.fromMillisecondsSinceEpoch(0));
    expect(stub.pathLength, -1);
  });

  testWidgets('pasting a full contact link fills in every field', (
    tester,
  ) async {
    final conn = _CapturingConn();
    await _open(tester, conn);

    await tester.enterText(
      find.byType(TextField).first,
      'meshcore://contact/add?name=Two+Words&public_key=$_key&type=2',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(conn.added, hasLength(1));
    final stub = conn.added.single;
    expect(stub.publicKeyHex, _key);
    // Name and type came from the pasted link, not retyped by hand.
    expect(stub.name, 'Two Words');
    expect(stub.type, advTypeRepeater);
  });

  testWidgets('whitespace in a pasted key is tolerated', (tester) async {
    final conn = _CapturingConn();
    await _open(tester, conn);

    // A key copied out of a chat log often arrives wrapped.
    await tester.enterText(
      find.byType(TextField).first,
      '${_key.substring(0, 32)}\n${_key.substring(32)}',
    );
    await tester.enterText(find.byType(TextField).last, 'Bob');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(conn.added, hasLength(1));
    expect(conn.added.single.publicKeyHex, _key);
  });

  testWidgets('an invalid key shows an error and sends nothing', (
    tester,
  ) async {
    final conn = _CapturingConn();
    await _open(tester, conn);

    await tester.enterText(find.byType(TextField).first, 'not-a-key');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(conn.added, isEmpty);
    // Dialog stays open so the user can correct it.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.textContaining('64 hex characters', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('a missing name falls back rather than blocking the add', (
    tester,
  ) async {
    final conn = _CapturingConn();
    await _open(tester, conn);

    await tester.enterText(find.byType(TextField).first, _key);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(conn.added, hasLength(1));
    expect(conn.added.single.name, 'Unknown');
  });
}
