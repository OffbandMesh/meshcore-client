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

/// #660 / #668: a radio declared 350 contacts, streamed 106, and the app
/// replaced the owner's saved list with the 106. A full sync must never drop a
/// contact unless the radio proved it sent everything.
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
    ..add(Uint8List(32)..setRange(0, name.length, utf8.encode(name)))
    ..add(_u32(1790000000)) // last advert
    ..add(_u32(0)) // lat
    ..add(_u32(0)) // lon
    ..add(_u32(1790000000)); // lastmod
  return b.toBytes();
}

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

Uint8List _start(int declared) =>
    Uint8List.fromList([respCodeContactsStart, ..._u32(declared)]);

Uint8List get _end => Uint8List.fromList([respCodeEndOfContacts, ..._u32(0)]);

Contact _saved(int keyByte, String name) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, keyByte)),
  name: name,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

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
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Set<String> names() => connector.contactsForTest.map((c) => c.name).toSet();

  int contactRequests() =>
      sent.where((f) => f.isNotEmpty && f[0] == cmdGetContacts).length;

  /// Seeds saved contacts A, B, C; the radio then streams [streamed] under a
  /// declared total of [declared].
  Future<void> fullSync({
    required int declared,
    required List<Uint8List> streamed,
  }) async {
    await connector.getContacts();
    connector.handleFrameForTest(_start(declared));
    for (final f in streamed) {
      connector.handleFrameForTest(f);
    }
    connector.handleFrameForTest(_end);
    await Future<void>.delayed(Duration.zero);
  }

  void seedSaved() {
    connector.contactsForTest
      ..add(_saved(0x11, 'Alpha'))
      ..add(_saved(0x22, 'Bravo'))
      ..add(_saved(0x33, 'Charlie'));
  }

  test('completeness needs a declared total and at least that many', () {
    expect(
      MeshCoreConnector.isContactSyncComplete(declared: 3, received: 3),
      isTrue,
    );
    expect(
      MeshCoreConnector.isContactSyncComplete(declared: 350, received: 106),
      isFalse,
    );
    expect(
      MeshCoreConnector.isContactSyncComplete(declared: null, received: 50),
      isFalse,
    );
  });

  test('starting a full sync does not clear the saved list', () async {
    seedSaved();
    await connector.getContacts();
    connector.handleFrameForTest(_start(3));
    expect(names(), {'Alpha', 'Bravo', 'Charlie'});
  });

  test('a complete sync replaces the list, removals included', () async {
    seedSaved();
    await fullSync(
      declared: 2,
      streamed: [_contactFrame(0x11, 'Alpha'), _contactFrame(0x44, 'Delta')],
    );

    expect(names(), {'Alpha', 'Delta'});
    expect(connector.contactSyncShortfall, isNull);
    expect(contactRequests(), 1, reason: 'no retry after a complete sync');
  });

  test('a short sync removes nothing, merges, reports, and retries', () async {
    seedSaved();
    await fullSync(
      declared: 350,
      streamed: [_contactFrame(0x11, 'Alpha'), _contactFrame(0x44, 'Delta')],
    );

    expect(names(), {'Alpha', 'Bravo', 'Charlie', 'Delta'});
    final shortfall = connector.contactSyncShortfall!;
    expect(shortfall.declared, 350);
    expect(shortfall.received, 2);
    expect(shortfall.keptLocally, 2);
    expect(connector.contactSyncDecisionPending, isFalse);
    expect(contactRequests(), 2, reason: 'one automatic retry');
  });

  test('no declared total is never treated as complete', () async {
    seedSaved();
    await connector.getContacts();
    connector.handleFrameForTest(Uint8List.fromList([respCodeContactsStart]));
    connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
    connector.handleFrameForTest(_end);
    await Future<void>.delayed(Duration.zero);

    expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    expect(connector.contactSyncShortfall!.declared, isNull);
  });

  group('after the retry is also short', () {
    Future<void> twoShortSyncs() async {
      seedSaved();
      final streamed = [_contactFrame(0x11, 'Alpha')];
      await fullSync(declared: 350, streamed: streamed);
      // The retry was sent by the first END; the radio answers it short too.
      connector.handleFrameForTest(_start(350));
      connector.handleFrameForTest(streamed.first);
      connector.handleFrameForTest(_end);
      await Future<void>.delayed(Duration.zero);
    }

    test('the owner decision is raised and nothing is removed', () async {
      await twoShortSyncs();

      expect(connector.contactSyncDecisionPending, isTrue);
      expect(connector.contactSyncUndeliveredCount, 2);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      expect(contactRequests(), 2, reason: 'retry is bounded to one');
    });

    test('keep my contacts leaves the list as is', () async {
      await twoShortSyncs();
      connector.resolveContactSyncKeepLocal();

      expect(connector.contactSyncDecisionPending, isFalse);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('use the radio list drops what it did not send', () async {
      await twoShortSyncs();
      await connector.resolveContactSyncUseRadio();

      expect(connector.contactSyncDecisionPending, isFalse);
      expect(connector.contactSyncShortfall, isNull);
      expect(names(), {'Alpha'});
    });
  });

  test('an advert heard mid-sync survives a complete sync', () async {
    seedSaved();
    await connector.getContacts();
    connector.handleFrameForTest(_start(1));
    connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
    connector.contactsForTest.add(_saved(0x55, 'Echo'));
    connector.handleFrameForTest(
      _contactFrame(0x55, 'Echo', code: pushCodeNewAdvert),
    );
    connector.handleFrameForTest(_end);
    await Future<void>.delayed(Duration.zero);

    expect(names(), {'Alpha', 'Echo'});
  });

  group('one contact request at a time (#672)', () {
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2026, 9, 23, 6);
      connector.contactSyncClock = () => now;
    });

    test('a request during a stream is queued, not sent, list kept', () async {
      seedSaved();
      await connector.getContacts();
      connector.handleFrameForTest(_start(3));
      connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));

      await connector.getContacts();

      expect(contactRequests(), 1);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('the queued request runs after END', () async {
      await connector.getContacts();
      connector.handleFrameForTest(_start(0));
      await connector.getContacts(since: 5, preserveExisting: true);
      connector.handleFrameForTest(_end);
      await Future<void>.delayed(Duration.zero);

      expect(contactRequests(), 2);
      expect(sent.last.length, 5, reason: 'the queued incremental request');
    });

    test('a queued full request wins over an incremental one', () async {
      await connector.getContacts();
      connector.handleFrameForTest(_start(0));
      await connector.getContacts(since: 5, preserveExisting: true);
      await connector.getContacts();
      connector.handleFrameForTest(_end);
      await Future<void>.delayed(Duration.zero);

      expect(contactRequests(), 2);
      expect(sent.last.length, 1, reason: 'a full request has no since');
    });

    test('ERR before the stream ends the request and keeps the list', () async {
      seedSaved();
      await connector.getContacts();
      connector.handleFrameForTest(Uint8List.fromList([respCodeErr, 4]));

      expect(connector.isLoadingContacts, isFalse);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      await connector.getContacts();
      expect(contactRequests(), 2, reason: 'no longer blocked');
    });

    test('a request idle for 30 s is treated as lost', () async {
      await connector.getContacts();
      connector.handleFrameForTest(_start(3));

      now = now.add(const Duration(seconds: 29));
      await connector.getContacts();
      expect(contactRequests(), 1, reason: 'still live at 29 s');

      now = now.add(const Duration(seconds: 2));
      await connector.getContacts();
      expect(contactRequests(), 2, reason: 'stale at 31 s');
    });

    test('contact frames keep a long stream alive', () async {
      await connector.getContacts();
      connector.handleFrameForTest(_start(3));
      now = now.add(const Duration(seconds: 25));
      connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
      now = now.add(const Duration(seconds: 25));

      await connector.getContacts();
      expect(contactRequests(), 1);
    });

    test('a failed send does not leave refreshes blocked', () async {
      connector.sendFrameOverrideForTest = (_) => throw Exception('usb gone');
      await expectLater(connector.getContacts(), throwsException);

      connector.sendFrameOverrideForTest = sent.add;
      await connector.getContacts();
      expect(contactRequests(), 1);
    });
  });

  test('an incremental sync never removes anything', () async {
    seedSaved();
    await connector.getContacts(since: 1, preserveExisting: true);
    connector.handleFrameForTest(_start(350));
    connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
    connector.handleFrameForTest(_end);
    await Future<void>.delayed(Duration.zero);

    expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    expect(connector.contactSyncShortfall, isNull);
    expect(contactRequests(), 1);
  });
}
