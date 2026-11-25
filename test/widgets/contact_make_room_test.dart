// #1028 / #1182: on a full radio the add is not sent until the user has chosen
// what comes off the radio. Owner test of the first build, 2026-11-24: the
// firmware overwrote a contact on its own because the app never asked.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/stale_contacts.dart' as stale_helper;
import 'package:meshcore_open/l10n/app_localizations.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/screens/prune_contacts_screen.dart';
import 'package:meshcore_open/widgets/add_contact_by_key_dialog.dart';
import 'package:meshcore_open/widgets/contact_add_feedback.dart';

const _newKey =
    '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

Contact _contact(int b, String name, int daysAgo) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, b)),
  receivedName: name,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.now().subtract(Duration(days: daysAgo)),
);

class _FullRadio extends MeshCoreConnector {
  _FullRadio({this.removal = ContactRemoveOutcome.removed});

  final ContactRemoveOutcome removal;
  bool full = true;
  final List<Contact> added = [];
  final List<Contact> removed = [];
  final List<Contact> held = [
    _contact(0x11, 'Fresh', 2),
    _contact(0x22, 'Old', 40),
    _contact(0x33, 'Oldest', 100),
  ];

  @override
  Future<ContactAddResult> addContactByKey(Contact stub) async {
    if (full) return ContactAddResult(ContactAddOutcome.full, name: stub.name);
    added.add(stub);
    return ContactAddResult(ContactAddOutcome.added, name: stub.name);
  }

  @override
  Contact? contactToMakeRoom() => stale_helper.leastRecentlyHeard(held);

  @override
  List<Contact> staleContacts(Duration olderThan) => stale_helper.staleContacts(
    held,
    now: DateTime.now(),
    olderThan: olderThan,
  );

  @override
  Future<ContactRemoveResult> removeContactFromRadio(Contact contact) async {
    if (removal != ContactRemoveOutcome.removed) {
      return ContactRemoveResult(removal, errCode: errCodeNotFound);
    }
    removed.add(contact);
    held.remove(contact);
    full = false;
    return const ContactRemoveResult(ContactRemoveOutcome.removed);
  }

  @override
  Future<ContactPruneResult> pruneContacts(List<Contact> contacts) async {
    for (final c in contacts) {
      await removeContactFromRadio(c);
    }
    return ContactPruneResult(contacts.length);
  }
}

Widget _app(MeshCoreConnector conn, Widget home) =>
    ChangeNotifierProvider<MeshCoreConnector>.value(
      value: conn,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

Future<void> _addBob(WidgetTester tester, MeshCoreConnector conn) async {
  await tester.pumpWidget(
    _app(
      conn,
      Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAddContactByKeyDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, _newKey);
  await tester.enterText(find.byType(TextField).last, 'Bob');
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}

void main() {
  group('an add on a full radio', () {
    testWidgets('asks first, naming the contact it suggests removing', (
      tester,
    ) async {
      final conn = _FullRadio();
      await _addBob(tester, conn);

      expect(find.text("The radio's contact list is full"), findsOneWidget);
      expect(find.text('Remove Oldest'), findsOneWidget);
      expect(find.text('Last heard 100 days ago'), findsOneWidget);
      expect(find.text('Prune stale contacts'), findsOneWidget);
      expect(conn.removed, isEmpty);
      expect(conn.added, isEmpty);
    });

    testWidgets('cancel removes nothing and adds nothing', (tester) async {
      final conn = _FullRadio();
      await _addBob(tester, conn);

      // The prompt sits over the add dialog, so its Cancel is the last one.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      expect(conn.removed, isEmpty);
      expect(conn.added, isEmpty);
    });

    testWidgets('choosing the suggestion removes it, then adds', (
      tester,
    ) async {
      final conn = _FullRadio();
      await _addBob(tester, conn);

      await tester.tap(find.text('Remove Oldest'));
      await tester.pumpAndSettle();

      expect(conn.removed.map((c) => c.name), ['Oldest']);
      expect(conn.added.map((c) => c.name), ['Bob']);
      expect(find.textContaining('Added Bob'), findsOneWidget);
    });

    testWidgets('a removal the radio refuses says why and adds nothing', (
      tester,
    ) async {
      final conn = _FullRadio(removal: ContactRemoveOutcome.refused);
      await _addBob(tester, conn);

      await tester.tap(find.text('Remove Oldest'));
      await tester.pumpAndSettle();

      expect(conn.added, isEmpty);
      expect(
        find.textContaining("Oldest was not removed: the radio didn't accept"),
        findsOneWidget,
      );
    });

    testWidgets('pruning from the prompt, then the add goes through', (
      tester,
    ) async {
      final conn = _FullRadio();
      await _addBob(tester, conn);

      await tester.tap(find.text('Prune stale contacts'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove 2'));
      await tester.pumpAndSettle();

      expect(conn.removed.map((c) => c.name), ['Oldest', 'Old']);
      expect(conn.added.map((c) => c.name), ['Bob']);
    });
  });

  // Gemini review: a pasted advert that does not parse returned null, and the
  // paste closed with no message at all.
  testWidgets('a pasted contact that does not parse says so', (tester) async {
    final conn = _FullRadio();
    await tester.pumpWidget(
      _app(
        conn,
        Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  addContactWithFeedback(context, conn, '', () async => null),
              child: const Text('paste'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('paste'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid contact data'), findsOneWidget);
    expect(conn.added, isEmpty);
  });

  group('the prune screen', () {
    testWidgets('lists contacts unheard for 30 days by default', (
      tester,
    ) async {
      final conn = _FullRadio();
      await tester.pumpWidget(_app(conn, const PruneContactsScreen()));

      expect(find.text('Oldest'), findsOneWidget);
      expect(find.text('Old'), findsOneWidget);
      expect(find.text('Fresh'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Remove 2'), findsOneWidget);
    });

    testWidgets('90 days narrows the list', (tester) async {
      final conn = _FullRadio();
      await tester.pumpWidget(_app(conn, const PruneContactsScreen()));

      await tester.tap(find.text('90 days'));
      await tester.pumpAndSettle();

      expect(find.text('Old'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Remove 1'), findsOneWidget);
    });

    testWidgets('an unticked contact is kept', (tester) async {
      final conn = _FullRadio();
      await tester.pumpWidget(_app(conn, const PruneContactsScreen()));

      await tester.tap(find.text('Old'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove 1'));
      await tester.pumpAndSettle();

      expect(conn.removed.map((c) => c.name), ['Oldest']);
    });
  });
}
