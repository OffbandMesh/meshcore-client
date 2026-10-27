// #890: an inbound remote-CLI command (TXT type 3) another contact sends to run
// on our radio reaches the app as a message. It must be accepted and flagged
// (isCliCommand), not warn-dropped as an unknown type.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A companion-layout contact-message frame (non-V3):
/// [code][prefix x6][path_len][txt_type][timestamp x4][text][0].
Uint8List _frame({
  required int txtType,
  required Uint8List pubKey,
  String text = 'get radio',
}) {
  final b = BytesBuilder();
  b.addByte(respCodeContactMsgRecv);
  b.add(pubKey.sublist(0, 6));
  b.addByte(0); // path_len
  b.addByte(txtType);
  b.add([0, 0, 0, 0]); // timestamp
  b.add(ascii.encode(text));
  b.addByte(0); // null terminator
  return b.toBytes();
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late Uint8List pubKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    pubKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    connector.contactsForTest.add(
      Contact(
        publicKey: pubKey,
        receivedName: 'Sender',
        type: advTypeChat,
        pathLength: 0,
        path: Uint8List(0),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  test('an inbound type-3 command is accepted and flagged (#890)', () {
    final msg = connector.parseContactMessageForTest(
      _frame(txtType: txtTypeCliCommand, pubKey: pubKey),
    );
    expect(msg, isNotNull, reason: 'type 3 must not be dropped');
    expect(msg!.isCliCommand, isTrue);
    expect(msg.isCli, isFalse);
    expect(msg.text, 'get radio');
  });

  test('a type-1 CLI_DATA reply is isCli, not isCliCommand', () {
    final msg = connector.parseContactMessageForTest(
      _frame(txtType: txtTypeCliData, pubKey: pubKey),
    );
    expect(msg, isNotNull);
    expect(msg!.isCli, isTrue);
    expect(msg.isCliCommand, isFalse);
  });

  test('a plain message is neither isCli nor isCliCommand', () {
    final msg = connector.parseContactMessageForTest(
      _frame(txtType: txtTypePlain, pubKey: pubKey, text: 'hi'),
    );
    expect(msg, isNotNull);
    expect(msg!.isCli, isFalse);
    expect(msg.isCliCommand, isFalse);
  });

  group('CLI traffic stays out of the chat thread (#999)', () {
    // CLI and chat are separate surfaces: a CLI reply (type-1) or an inbound
    // CLI command (type-3) is the CLI console's concern, correlated via the
    // receivedFrames listener. It must never land in the contact's
    // conversation. The console is tested in cli_console_transport_test.
    setUp(() {
      // The incoming-message path bails without a self identity; set one
      // distinct from the sender so nothing is mistaken for an echo of self.
      connector.setSelfPublicKeyForTest(
        Uint8List.fromList(List<int>.filled(32, 0xAA)),
      );
    });

    Iterable<dynamic> allMessages() =>
        connector.conversationsForTest.values.expand((m) => m);

    test('a type-1 CLI reply does not enter the conversation', () async {
      connector.handleFrameForTest(
        _frame(txtType: txtTypeCliData, pubKey: pubKey, text: 'A1|radio ok'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(allMessages(), isEmpty);
    });

    test(
      'an inbound type-3 CLI command does not enter the conversation',
      () async {
        connector.handleFrameForTest(
          _frame(txtType: txtTypeCliCommand, pubKey: pubKey, text: 'reboot'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(allMessages(), isEmpty);
      },
    );

    test('a plain message does enter the conversation', () async {
      connector.handleFrameForTest(
        _frame(txtType: txtTypePlain, pubKey: pubKey, text: 'hi there'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(allMessages(), isNotEmpty);
    });
  });
}
