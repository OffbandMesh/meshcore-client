import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #838 Option A (sync is truth): a live advert the client overhears must NOT be
// promoted into the persisted contact list (that is what drifted a long session
// above radio truth). It feeds discovery only, and nudges a reconcile so a
// contact the radio actually added still surfaces. Only the sync stream, which
// is radio truth, populates the contact list.
Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// A contact-stream / NEW_ADVERT frame in the respCodeContact layout.
Uint8List _contactFrame(
  int keyByte,
  String name, {
  int code = respCodeContact,
}) {
  final b = BytesBuilder()
    ..addByte(code)
    ..add(List<int>.filled(32, keyByte))
    ..addByte(advTypeChat)
    ..addByte(0) // flags
    ..addByte(0xFF) // flood path
    ..add(List<int>.filled(64, 0))
    ..add(Uint8List(32)..setRange(0, name.length, name.codeUnits))
    ..add(_u32(1790000000))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(1790000000));
  return b.toBytes();
}

/// A raw over-the-air advert wrapped in PUSH_CODE_LOG_RX_DATA (0x88), the
/// firehose the radio sends for everything it hears. routeType 0x01 keeps it
/// off the flood/direct transport-byte path.
Uint8List _rxAdvertFrame(int keyByte, String name) {
  final header = (payloadTypeADVERT << 2) | 0x01;
  final payload = BytesBuilder()
    ..add(List<int>.filled(32, keyByte))
    ..add(_u32(1790000000)) // timestamp
    ..add(List<int>.filled(64, 0)) // signature
    ..addByte(advTypeChat | 0x80) // type + hasName
    ..add(name.codeUnits)
    ..addByte(0); // C-string terminator
  return (BytesBuilder()
        ..addByte(pushCodeLogRxData)
        ..addByte(0) // snr
        ..addByte(0) // rssi
        ..addByte(header)
        ..addByte(0) // pathLenRaw -> no path
        ..add(payload.toBytes()))
      .toBytes();
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
    // The radio's auto-add policy says chat nodes are eligible; pre-fix this is
    // exactly what made the client promote every overheard chat advert.
    connector.handleFrameForTest(
      Uint8List.fromList([respCodeAutoAddConfig, autoAddChatFlag]),
    );
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Set<String> contactNames() =>
      connector.contactsForTest.map((c) => c.name).toSet();
  Set<String> discoveredNames() =>
      connector.discoveredContactsForTest.map((c) => c.name).toSet();
  int getContactsRequests() =>
      sent.where((f) => f.isNotEmpty && f[0] == cmdGetContacts).length;

  test(
    'a NEW_ADVERT push for an unknown node stays out of the contact list',
    () async {
      connector.handleFrameForTest(
        _contactFrame(0x44, 'Delta', code: pushCodeNewAdvert),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        contactNames(),
        isNot(contains('Delta')),
        reason: 'a live advert must not be promoted to a persisted contact',
      );
      expect(
        discoveredNames(),
        contains('Delta'),
        reason: 'it belongs in discovery instead',
      );
    },
  );

  test(
    'a raw over-the-air advert (0x88) stays out of the contact list',
    () async {
      connector.handleFrameForTest(_rxAdvertFrame(0x55, 'Echo'));
      await Future<void>.delayed(Duration.zero);

      expect(contactNames(), isNot(contains('Echo')));
      expect(discoveredNames(), contains('Echo'));
    },
  );

  test(
    'an unknown auto-add-eligible advert nudges a contact reconcile',
    () async {
      final before = getContactsRequests();
      connector.handleFrameForTest(
        _contactFrame(0x66, 'Foxtrot', code: pushCodeNewAdvert),
      );
      // The reconcile is debounced; give it room to fire.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      expect(
        getContactsRequests(),
        greaterThan(before),
        reason: 'a new advert should pull the radio truth, not add locally',
      );
    },
  );

  test(
    'the contact sync stream still populates the list (sync is truth)',
    () async {
      await connector.getContacts();
      connector.handleFrameForTest(
        Uint8List.fromList([respCodeContactsStart, ..._u32(1)]),
      );
      connector.handleFrameForTest(_contactFrame(0x77, 'Golf'));
      connector.handleFrameForTest(
        Uint8List.fromList([respCodeEndOfContacts, ..._u32(0)]),
      );
      await Future<void>.delayed(Duration.zero);

      expect(contactNames(), contains('Golf'));
    },
  );

  test('a NEW_ADVERT for an EXISTING contact still refreshes it', () async {
    await connector.getContacts();
    connector.handleFrameForTest(
      Uint8List.fromList([respCodeContactsStart, ..._u32(1)]),
    );
    connector.handleFrameForTest(_contactFrame(0x88, 'Hotel'));
    connector.handleFrameForTest(
      Uint8List.fromList([respCodeEndOfContacts, ..._u32(0)]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(contactNames(), contains('Hotel'));

    // A later advert for the same node must keep it (it is radio truth).
    connector.handleFrameForTest(
      _contactFrame(0x88, 'Hotel', code: pushCodeNewAdvert),
    );
    await Future<void>.delayed(Duration.zero);
    expect(contactNames(), contains('Hotel'));
  });
}
