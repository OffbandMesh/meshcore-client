// #1182 (part of #1028): removing contacts from a full radio only with the
// user's say-so, one at a time, each confirmed by the radio, keeping the DMs.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/stale_contacts.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

final _now = DateTime.utc(2026, 11, 24, 12);

Contact _contact(
  int keyByte,
  String name, {
  int daysAgo = 0,
  bool favorite = false,
  DateTime? lastModified,
}) {
  final heard = _now.subtract(Duration(days: daysAgo));
  return Contact(
    publicKey: _key(keyByte),
    receivedName: name,
    type: advTypeChat,
    flags: favorite ? contactFlagFavorite : 0,
    pathLength: -1,
    path: Uint8List(0),
    lastSeen: heard,
    lastModified: lastModified,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stale contacts', () {
    final contacts = [
      _contact(0x11, 'Fresh', daysAgo: 2),
      _contact(0x22, 'Old', daysAgo: 40),
      _contact(0x33, 'Older', daysAgo: 100),
      _contact(0x44, 'Old favorite', daysAgo: 200, favorite: true),
    ];

    test('are non-favorites older than the cutoff, oldest first', () {
      final stale = staleContacts(
        contacts,
        now: _now,
        olderThan: const Duration(days: 30),
      );
      expect(stale.map((c) => c.name), ['Older', 'Old']);
    });

    test('the longest window lists only the oldest', () {
      final stale = staleContacts(
        contacts,
        now: _now,
        olderThan: const Duration(days: 90),
      );
      expect(stale.map((c) => c.name), ['Older']);
    });

    test('a recent radio change counts as heard', () {
      final touched = _contact(
        0x55,
        'Touched',
        daysAgo: 100,
        lastModified: _now.subtract(const Duration(days: 1)),
      );
      expect(
        staleContacts(
          [touched],
          now: _now,
          olderThan: const Duration(days: 30),
        ),
        isEmpty,
      );
    });

    test('an excluded key is never listed', () {
      final stale = staleContacts(
        contacts,
        now: _now,
        olderThan: const Duration(days: 30),
        exclude: {_contact(0x33, '').publicKeyHex},
      );
      expect(stale.map((c) => c.name), ['Old']);
    });

    test('the suggestion is the least recently heard non-favorite', () {
      expect(leastRecentlyHeard(contacts)?.name, 'Older');
    });

    test('there is no suggestion when every contact is a favorite', () {
      expect(
        leastRecentlyHeard([_contact(0x44, 'Fav', daysAgo: 9, favorite: true)]),
        isNull,
      );
    });

    test('the choices are 15, 30 and 90 days, 30 by default', () {
      expect(pruneDayChoices, [15, 30, 90]);
      expect(defaultPruneDays, 30);
    });
  });

  group('removing from the radio', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;
    late List<Uint8List> sent;

    void ok() => connector.handleFrameForTest([respCodeOk]);
    void err(int code) => connector.handleFrameForTest([respCodeErr, code]);
    bool holds(int b) => connector.contactsForTest.any(
      (c) => c.publicKeyHex == _contact(b, '').publicKeyHex,
    );
    Iterable<Uint8List> framesOf(int cmd) =>
        sent.where((f) => f.isNotEmpty && f[0] == cmd);

    Future<void> settle([int turns = 25]) async {
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// Answers each removal the radio is sent, in order, with [replies]
    /// (null for OK, an error code for ERR).
    Future<void> answerRemovals(List<int?> replies) async {
      for (var i = 0; i < replies.length; i++) {
        for (
          var t = 0;
          t < 500 && framesOf(cmdRemoveContact).length <= i;
          t++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final reply = replies[i];
        reply == null ? ok() : err(reply);
        await settle(2);
      }
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      connector = MeshCoreConnector();
      connector.contactsForTest
        ..clear()
        ..addAll([
          _contact(0x11, 'Alpha', daysAgo: 60),
          _contact(0x22, 'Bravo', daysAgo: 45),
          _contact(0x33, 'Charlie', daysAgo: 1),
        ]);
      connector.setConnectedForTest();
      sent = [];
      connector.sendFrameOverrideForTest = sent.add;
    });

    tearDown(() async {
      await db.close();
      BlobStore.clearTestOverride();
    });

    test('OK removes the contact here and keeps its DMs', () async {
      final alpha = connector.contactsForTest.first;
      connector.conversationsForTest[alpha.publicKeyHex] = [
        Message(
          senderKey: alpha.publicKey,
          text: 'hi',
          timestamp: _now,
          isOutgoing: true,
        ),
      ];

      final removal = connector.removeContactFromRadio(alpha);
      await settle(2);
      expect(framesOf(cmdRemoveContact).single.sublist(1, 33), alpha.publicKey);
      ok();

      expect((await removal).outcome, ContactRemoveOutcome.removed);
      expect(holds(0x11), isFalse);
      expect(connector.conversationsForTest[alpha.publicKeyHex], isNotEmpty);
    });

    test('a refusal keeps the contact', () async {
      final removal = connector.removeContactFromRadio(
        connector.contactsForTest.first,
      );
      await settle(2);
      err(errCodeNotFound);

      final result = await removal;
      expect(result.outcome, ContactRemoveOutcome.refused);
      expect(result.errCode, errCodeNotFound);
      expect(holds(0x11), isTrue);
    });

    test('no answer keeps the contact', () async {
      connector.contactAddReplyTimeout = const Duration(milliseconds: 20);
      final result = await connector.removeContactFromRadio(
        connector.contactsForTest.first,
      );
      expect(result.outcome, ContactRemoveOutcome.noReply);
      expect(holds(0x11), isTrue);
    });

    test('a confirmed removal makes room for the next add', () async {
      connector.handleFrameForTest([pushCodeContactsFull]);
      expect(connector.radioContactsFull, isTrue);

      final removal = connector.removeContactFromRadio(
        connector.contactsForTest.first,
      );
      await settle(2);
      ok();
      await removal;
      expect(connector.radioContactsFull, isFalse);

      final add = connector.addContactByKey(_contact(0x66, 'New'));
      await settle(2);
      ok();
      expect((await add).outcome, ContactAddOutcome.added);
    });

    test('a full radio reports full and sends nothing', () async {
      connector.handleFrameForTest([pushCodeContactsFull]);
      final result = await connector.addContactByKey(_contact(0x66, 'New'));
      expect(result.outcome, ContactAddOutcome.full);
      expect(framesOf(cmdAddUpdateContact), isEmpty);
    });

    test('a table-full refusal marks the radio full', () async {
      final add = connector.addContactByKey(_contact(0x66, 'New'));
      await settle(2);
      err(errCodeTableFull);
      await add;
      expect(connector.radioContactsFull, isTrue);
    });

    test('pruning removes each in turn, waiting for every OK', () async {
      final targets = connector.contactsForTest.take(2).toList();
      final prune = connector.pruneContacts(targets);
      await answerRemovals([null, null]);

      final result = await prune;
      expect(result.removed, 2);
      expect(result.failed, isNull);
      expect(connector.contactsForTest.map((c) => c.name), ['Charlie']);
    });

    test('pruning stops at the first refusal and says which', () async {
      final targets = connector.contactsForTest.take(2).toList();
      final prune = connector.pruneContacts(targets);
      await answerRemovals([null, errCodeNotFound]);

      final result = await prune;
      expect(result.removed, 1);
      expect(result.failed?.name, 'Bravo');
      expect(result.failure?.errCode, errCodeNotFound);
      expect(holds(0x22), isTrue);
    });

    test('a contact added on this connection is never stale', () async {
      final add = connector.addContactByKey(_contact(0x77, 'Just added'));
      await settle(2);
      ok();
      await add;

      final names = connector
          .staleContacts(const Duration(days: 30))
          .map((c) => c.name);
      expect(names, isNot(contains('Just added')));
      expect(names, containsAll(['Alpha', 'Bravo']));
    });
  });
}
