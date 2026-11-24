// #1028: what the user is told when the radio refuses, ignores, or makes room
// for a contact, and why a refused DM failed. contact_add_confirm_test.dart
// covers the behavior with dev's API; this file covers what #1028 adds.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

Contact _contact(int keyByte, String name) => Contact(
  publicKey: _key(keyByte),
  receivedName: name,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List _contactFrame(int keyByte, String name) {
  final b = BytesBuilder()
    ..addByte(respCodeContact)
    ..add(_key(keyByte))
    ..addByte(advTypeChat)
    ..addByte(0)
    ..addByte(0xFF)
    ..add(List<int>.filled(64, 0))
    ..add(Uint8List(32)..setRange(0, name.length, utf8.encode(name)))
    ..add(_u32(1790000000))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(1790000000));
  return b.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  void ok() => connector.handleFrameForTest([respCodeOk]);
  void err(int code) => connector.handleFrameForTest([respCodeErr, code]);

  Future<void> settle([int turns = 25]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
    connector.setConnectedForTest();
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  group('the add result says what the radio did', () {
    test('OK is added', () async {
      final add = connector.addContactByKey(_contact(0x11, 'Alpha'));
      await settle(2);
      ok();
      final result = await add;
      expect(result.outcome, ContactAddOutcome.added);
      expect(connector.contactTableNotice, isNull);
    });

    test('table full is refused, says full, and raises the notice', () async {
      final add = connector.addContactByKey(_contact(0x11, 'Alpha'));
      await settle(2);
      err(errCodeTableFull);
      final result = await add;
      expect(result.outcome, ContactAddOutcome.refused);
      expect(result.radioFull, isTrue);
      expect(connector.contactTableNotice, isNotNull);
      expect(connector.contactTableNotice!.removedName, isNull);
    });

    test('another error is refused with its code, and is not "full"', () async {
      final add = connector.importDiscoveredContact(_contact(0x11, 'Alpha'));
      await settle(2);
      err(errCodeIllegalArg);
      final result = await add;
      expect(result.outcome, ContactAddOutcome.refused);
      expect(result.errCode, errCodeIllegalArg);
      expect(result.radioFull, isFalse);
      expect(connector.contactTableNotice, isNull);
    });

    test('no answer is noReply and keeps no contact', () async {
      connector.contactAddReplyTimeout = const Duration(milliseconds: 20);
      final result = await connector.addContactByKey(_contact(0x11, 'Alpha'));
      expect(result.outcome, ContactAddOutcome.noReply);
      expect(connector.contactsForTest, isEmpty);
    });

    test('a timed-out add cannot take the next command\'s reply', () async {
      connector.contactAddReplyTimeout = const Duration(milliseconds: 20);
      await connector.addContactByKey(_contact(0x11, 'Alpha'));

      connector.contactAddReplyTimeout = const Duration(seconds: 5);
      final second = connector.addContactByKey(_contact(0x22, 'Bravo'));
      await settle(2);
      ok();
      expect((await second).outcome, ContactAddOutcome.added);
    });

    test('disconnected sends nothing', () async {
      final fresh = MeshCoreConnector();
      fresh.sendFrameOverrideForTest = sent.add;
      final result = await fresh.addContactByKey(_contact(0x11, 'Alpha'));
      expect(result.outcome, ContactAddOutcome.notConnected);
      expect(sent, isEmpty);
    });
  });

  group('the contact table notice', () {
    test('names the contact the radio removed to make room', () async {
      final add = connector.addContactByKey(_contact(0x44, 'Delta'));
      await settle(2);
      ok();
      await add;

      connector.handleFrameForTest([pushCodeContactDeleted, ..._key(0x44)]);
      expect(connector.contactTableNotice?.removedName, 'Delta');
    });

    test('a removal of a contact the app did not hold raises nothing', () {
      connector.handleFrameForTest([pushCodeContactDeleted, ..._key(0x99)]);
      expect(connector.contactTableNotice, isNull);
    });

    test('the radio reporting itself full raises it', () {
      connector.handleFrameForTest([pushCodeContactsFull]);
      expect(connector.contactTableNotice, isNotNull);
    });

    test('a complete sync at capacity raises it', () async {
      connector.maxContactsForTest = 2;
      await connector.getContacts();
      connector.handleFrameForTest([respCodeContactsStart, ..._u32(2)]);
      connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
      connector.handleFrameForTest(_contactFrame(0x22, 'Bravo'));
      connector.handleFrameForTest([respCodeEndOfContacts, ..._u32(0)]);
      await settle();
      expect(connector.contactTableNotice, isNotNull);
    });

    test('a complete sync below capacity raises nothing', () async {
      connector.maxContactsForTest = 3;
      await connector.getContacts();
      connector.handleFrameForTest([respCodeContactsStart, ..._u32(2)]);
      connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
      connector.handleFrameForTest(_contactFrame(0x22, 'Bravo'));
      connector.handleFrameForTest([respCodeEndOfContacts, ..._u32(0)]);
      await settle();
      expect(connector.contactTableNotice, isNull);
    });

    test('dismissing clears it', () {
      connector.handleFrameForTest([pushCodeContactsFull]);
      connector.dismissContactTableNotice();
      expect(connector.contactTableNotice, isNull);
    });
  });

  group('a refused DM', () {
    late Contact charlie;

    setUp(() {
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
      );
      connector.sendFrameOverrideForTest = sent.add;
      charlie = _contact(0x33, 'Charlie');
    });

    Future<void> untilDmsSent(int count) async {
      for (var i = 0; i < 500; i++) {
        if (sent.where((f) => f.isNotEmpty && f[0] == cmdSendTxtMsg).length >=
            count) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      fail('the DM was never sent');
    }

    Message? last(Contact c) =>
        connector.conversationsForTest[c.publicKeyHex]?.last;

    test('keeps the radio\'s reason', () async {
      await connector.sendMessage(charlie, 'hello');
      await untilDmsSent(1);
      err(errCodeNotFound);
      await settle();
      expect(last(charlie)?.radioErrorCode, errCodeNotFound);
    });

    test('an ERR during a contact sync is not taken as the DM\'s', () async {
      await connector.sendMessage(charlie, 'hello');
      await untilDmsSent(1);
      await connector.getContacts();
      err(errCodeNotFound);
      await settle();
      expect(last(charlie)?.status, MessageStatus.pending);
    });

    test('with two DMs waiting, an ERR fails neither', () async {
      final delta = _contact(0x44, 'Delta');
      await connector.sendMessage(charlie, 'one');
      await connector.sendMessage(delta, 'two');
      await untilDmsSent(2);
      err(errCodeNotFound);
      await settle();
      expect(last(charlie)?.status, MessageStatus.pending);
      expect(last(delta)?.status, MessageStatus.pending);
    });
  });

  group('the stored reason', () {
    final failed = Message(
      senderKey: _key(0x33),
      text: 'hello',
      timestamp: DateTime.utc(2026, 11, 24),
      isOutgoing: true,
      status: MessageStatus.failed,
      radioErrorCode: errCodeNotFound,
    );

    test('a resend clears it', () {
      final resent = failed.copyWith(status: MessageStatus.pending);
      expect(resent.radioErrorCode, isNull);
    });

    test('an unrelated update keeps it', () {
      expect(failed.copyWith(retryCount: 1).radioErrorCode, errCodeNotFound);
    });
  });
}
