// #1028: the app kept contacts the radio had refused, and a DM the radio
// refused sat pending for 8 s with no reason.
//
// From the owner's log: CMD_ADD_UPDATE_CONTACT drew ERR 3 (table full), the
// app logged "Added new contact" anyway, and every DM to that contact then
// drew ERR 2 (not found) and was marked failed only when the 8 s timer ran
// out. These tests use only what dev already has, so each one fails there.

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
Uint8List _psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

Contact _contact(int keyByte, String name) => Contact(
  publicKey: _key(keyByte),
  receivedName: name,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  void ok() => connector.handleFrameForTest([respCodeOk]);
  void err(int code) => connector.handleFrameForTest([respCodeErr, code]);
  bool holds(int keyByte) => connector.contactsForTest.any(
    (c) => c.publicKeyHex == _contact(keyByte, '').publicKeyHex,
  );

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

  group('add by key', () {
    test('the radio refusing the add (table full) keeps no contact', () async {
      final add = connector.addContactByKey(_contact(0x11, 'Alpha'));
      await settle(2);
      err(3);
      await add;

      expect(holds(0x11), isFalse);
    });

    test('the radio confirming the add keeps the contact', () async {
      final add = connector.addContactByKey(_contact(0x11, 'Alpha'));
      await settle(2);
      ok();
      await add;

      expect(holds(0x11), isTrue);
    });
  });

  group('add from Discovery', () {
    test('the radio refusing the add (table full) keeps no contact', () async {
      final add = connector.importDiscoveredContact(_contact(0x22, 'Bravo'));
      await settle(2);
      err(3);
      await add;

      expect(holds(0x22), isFalse);
    });

    test('the radio confirming the add keeps the contact', () async {
      final add = connector.importDiscoveredContact(_contact(0x22, 'Bravo'));
      await settle(2);
      ok();
      await add;

      expect(holds(0x22), isTrue);
    });

    // The Discovery add never waited for its own reply, so its ERR was taken
    // as the answer to whatever command was waiting next.
    test('its refusal is not taken as the next command\'s answer', () async {
      final add = connector.importDiscoveredContact(_contact(0x22, 'Bravo'));
      await settle(2);
      final write = connector.setChannel(
        3,
        'Weather',
        _psk(0x22),
        refresh: false,
      );
      await settle(2);
      err(3); // the radio refuses the add
      ok(); // and accepts the channel write

      await add;
      expect(await write, ChannelWrite.ok);
    });
  });

  group('a DM the radio refuses', () {
    late Contact bravo;

    setUp(() {
      connector.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
      );
      connector.sendFrameOverrideForTest = sent.add;
      bravo = _contact(0x33, 'Charlie');
    });

    Future<void> untilDmSent() async {
      for (var i = 0; i < 500; i++) {
        if (sent.any((f) => f.isNotEmpty && f[0] == cmdSendTxtMsg)) return;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      fail('the DM was never sent');
    }

    MessageStatus? statusOfLast() =>
        connector.conversationsForTest[bravo.publicKeyHex]?.last.status;

    test('fails at once when the radio answers not found', () async {
      await connector.sendMessage(bravo, 'hello');
      await untilDmSent();
      err(errCodeNotFound);
      await settle();

      expect(statusOfLast(), MessageStatus.failed);
    });

    test('is not failed by the radio confirming the send', () async {
      await connector.sendMessage(bravo, 'hello');
      await untilDmSent();
      connector.handleFrameForTest([
        respCodeSent,
        1,
        0x01, 0x02, 0x03, 0x04, // expected ack hash
        0x10, 0x27, 0x00, 0x00, // timeout 10000 ms
      ]);
      await settle();

      expect(statusOfLast(), isNot(MessageStatus.failed));
    });
  });

  group('the radio removing a contact to make room', () {
    test('removes it from the app\'s contacts too', () async {
      final add = connector.addContactByKey(_contact(0x44, 'Delta'));
      await settle(2);
      ok();
      await add;
      expect(holds(0x44), isTrue);

      connector.handleFrameForTest([0x8F, ..._key(0x44)]);
      await settle();

      expect(holds(0x44), isFalse);
    });

    test('leaves every other contact alone', () async {
      for (final b in [0x44, 0x55]) {
        final add = connector.addContactByKey(_contact(b, 'N$b'));
        await settle(2);
        ok();
        await add;
      }

      connector.handleFrameForTest([0x8F, ..._key(0x44)]);
      await settle();

      expect(holds(0x55), isTrue);
    });
  });
}
