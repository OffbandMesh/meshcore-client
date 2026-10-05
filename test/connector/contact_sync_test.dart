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
    connector.contactRecoverySettle = Duration.zero;
    connector.contactKeyCheckGap = Duration.zero;
    connector.contactKeyCheckTimeout = const Duration(milliseconds: 20);
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

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  int byKeyRequests() =>
      sent.where((f) => f.isNotEmpty && f[0] == cmdGetContactByKey).length;

  /// Answers the recovery request the app just sent with [streamed].
  Future<void> answerStream(int? declared, List<Uint8List> streamed) async {
    connector.handleFrameForTest(
      declared == null
          ? Uint8List.fromList([respCodeContactsStart])
          : _start(declared),
    );
    for (final f in streamed) {
      connector.handleFrameForTest(f);
    }
    connector.handleFrameForTest(_end);
    await settle();
  }

  /// Three short full syncs that each deliver only Alpha; the by-key checks
  /// that follow get no reply, so every missing contact stays unresolved.
  Future<void> threeShortSyncs({int? declared = 350}) async {
    seedSaved();
    final alpha = [_contactFrame(0x11, 'Alpha')];
    await connector.getContacts();
    await answerStream(declared, alpha);
    await answerStream(declared, alpha);
    await answerStream(declared, alpha);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  test('a short sync removes nothing, merges, and recovers quietly', () async {
    seedSaved();
    await fullSync(
      declared: 350,
      streamed: [_contactFrame(0x11, 'Alpha'), _contactFrame(0x44, 'Delta')],
    );
    await settle();

    expect(names(), {'Alpha', 'Bravo', 'Charlie', 'Delta'});
    expect(
      connector.contactSyncShortfall,
      isNull,
      reason: 'no banner while recovery is still running',
    );
    expect(connector.contactSyncDecisionPending, isFalse);
    expect(contactRequests(), 2, reason: 'recovery sync after the settle');
  });

  test('no declared total is never treated as complete', () async {
    await threeShortSyncs(declared: null);

    expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    expect(connector.contactSyncShortfall!.declared, isNull);
    expect(connector.contactSyncDecisionPending, isTrue);
  });

  group('still short after three full syncs', () {
    test('stops at three, checks the rest by key, removes nothing', () async {
      await threeShortSyncs();

      expect(contactRequests(), 3, reason: 'owner cap: 3 per connection');
      expect(byKeyRequests(), 2, reason: 'Bravo and Charlie, one each');
      expect(connector.contactSyncDecisionPending, isTrue);
      expect(connector.contactSyncUndeliveredCount, 2);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      final shortfall = connector.contactSyncShortfall!;
      expect(shortfall.declared, 350);
      expect(shortfall.received, 1);
      expect(shortfall.keptLocally, 2);
    });

    test('keep my contacts leaves the list as is', () async {
      await threeShortSyncs();
      connector.resolveContactSyncKeepLocal();

      expect(connector.contactSyncDecisionPending, isFalse);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('use the radio list drops what no sync delivered', () async {
      await threeShortSyncs();
      await connector.resolveContactSyncUseRadio();

      expect(connector.contactSyncDecisionPending, isFalse);
      expect(connector.contactSyncShortfall, isNull);
      expect(names(), {'Alpha'});
    });
  });

  group('forced resync (#703)', () {
    test('the cap and pacing defaults are pinned', () {
      expect(MeshCoreConnector.contactSyncMaxFullStreams, 3);
      expect(
        MeshCoreConnector.defaultContactRecoverySettle,
        const Duration(seconds: 10),
      );
      expect(
        MeshCoreConnector.defaultContactKeyCheckGap,
        const Duration(milliseconds: 250),
      );
      expect(
        MeshCoreConnector().contactKeyCheckTimeout,
        const Duration(seconds: 5),
      );
    });

    test(
      'syncs that each miss different contacts add up to complete',
      () async {
        seedSaved();
        await connector.getContacts();
        await answerStream(3, [
          _contactFrame(0x11, 'Alpha'),
          _contactFrame(0x22, 'Bravo'),
        ]);
        await answerStream(3, [
          _contactFrame(0x22, 'Bravo'),
          _contactFrame(0x33, 'Charlie'),
        ]);
        await settle();

        expect(contactRequests(), 2, reason: 'no third sync once complete');
        expect(byKeyRequests(), 0);
        expect(connector.contactSyncShortfall, isNull);
        expect(connector.contactSyncDecisionPending, isFalse);
        expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      },
    );

    test('only a contact the radio says is gone is removed', () async {
      seedSaved();
      connector.contactsForTest.add(_saved(0x44, 'Delta'));
      await connector.getContacts();
      await answerStream(3, [
        _contactFrame(0x11, 'Alpha'),
        _contactFrame(0x22, 'Bravo'),
      ]);
      await answerStream(3, [
        _contactFrame(0x11, 'Alpha'),
        _contactFrame(0x33, 'Charlie'),
      ]);
      expect(byKeyRequests(), 1, reason: 'Delta, the only one missing');
      connector.handleFrameForTest(
        Uint8List.fromList([respCodeErr, errCodeNotFound]),
      );
      await settle();

      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      expect(connector.contactSyncShortfall, isNull);
    });

    test(
      'a contact with no answer is kept even when the rest add up',
      () async {
        seedSaved();
        connector.contactsForTest.add(_saved(0x44, 'Delta'));
        await connector.getContacts();
        await answerStream(3, [
          _contactFrame(0x11, 'Alpha'),
          _contactFrame(0x22, 'Bravo'),
        ]);
        await answerStream(3, [_contactFrame(0x33, 'Charlie')]);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(names(), {'Alpha', 'Bravo', 'Charlie', 'Delta'});
      },
    );

    test('a by-key answer counts toward complete', () async {
      seedSaved();
      await connector.getContacts();
      final alpha = [_contactFrame(0x11, 'Alpha')];
      await answerStream(3, alpha);
      await answerStream(3, alpha);
      await answerStream(3, alpha);
      connector.handleFrameForTest(_contactFrame(0x22, 'Bravo'));
      await settle();
      connector.handleFrameForTest(_contactFrame(0x33, 'Charlie'));
      await settle();

      expect(connector.contactSyncShortfall, isNull);
      expect(connector.contactSyncDecisionPending, isFalse);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('a disconnect mid-recovery stops it and removes nothing', () async {
      seedSaved();
      connector.contactRecoverySettle = const Duration(milliseconds: 30);
      await fullSync(declared: 350, streamed: [_contactFrame(0x11, 'Alpha')]);
      connector.resetConnectionHandshakeStateForTest();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(contactRequests(), 1, reason: 'no recovery after disconnect');
      expect(byKeyRequests(), 0);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('a new connection starts with no recovery state', () async {
      seedSaved();
      await connector.getContacts();
      await answerStream(3, [
        _contactFrame(0x11, 'Alpha'),
        _contactFrame(0x22, 'Bravo'),
      ]);
      connector.resetConnectionHandshakeStateForTest();

      await connector.getContacts();
      await answerStream(3, [_contactFrame(0x11, 'Alpha')]);

      expect(
        connector.contactSyncUndeliveredCount,
        2,
        reason: 'Bravo from the old connection must not count',
      );
    });

    test('a contact the radio holds again after "not found" is kept', () async {
      seedSaved();
      connector.contactsForTest
        ..add(_saved(0x44, 'Delta'))
        ..add(_saved(0x55, 'Echo'));
      await connector.getContacts();
      await answerStream(3, [
        _contactFrame(0x11, 'Alpha'),
        _contactFrame(0x22, 'Bravo'),
      ]);
      await answerStream(3, [_contactFrame(0x33, 'Charlie')]);
      connector.handleFrameForTest(
        Uint8List.fromList([respCodeErr, errCodeNotFound]),
      );
      await settle();
      connector.handleFrameForTest(
        _contactFrame(0x44, 'Delta', code: pushCodeNewAdvert),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(names(), contains('Delta'));
    });

    test('a busy link cannot hide a short sync', () async {
      var now = DateTime.utc(2026, 10, 2, 6);
      connector.contactSyncClock = () => now;
      connector.contactRecoverySettle = const Duration(milliseconds: 10);
      seedSaved();
      await fullSync(declared: 350, streamed: [_contactFrame(0x11, 'Alpha')]);
      now = now.add(MeshCoreConnector.contactRecoveryMaxWait);
      connector.handleFrameForTest(
        Uint8List.fromList([pushCodeAdvert, ...List<int>.filled(32, 0x11)]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(contactRequests(), 1, reason: 'no sync onto a busy link');
      expect(byKeyRequests(), 0);
      expect(connector.contactSyncDecisionPending, isTrue);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test('the latest declared total decides the result', () async {
      connector.contactKeyCheckTimeout = const Duration(milliseconds: 100);
      seedSaved();
      final alpha = [_contactFrame(0x11, 'Alpha')];
      await connector.getContacts();
      await answerStream(350, alpha);
      await answerStream(350, alpha);
      await answerStream(350, alpha);
      // By-key checks are running; a refresh reports a new total of 2, and
      // Charlie turns up while the checks are still going.
      await connector.getContacts();
      await answerStream(2, alpha);
      connector.handleFrameForTest(_contactFrame(0x33, 'Charlie'));
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(connector.contactSyncShortfall, isNull);
      expect(connector.contactSyncDecisionPending, isFalse);
      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
    });

    test(
      'a complete sync during the by-key checks ends the recovery',
      () async {
        seedSaved();
        final alpha = [_contactFrame(0x11, 'Alpha')];
        await connector.getContacts();
        await answerStream(350, alpha);
        await answerStream(350, alpha);
        await answerStream(350, alpha);
        // The by-key checks are running; a refresh now comes back complete.
        await connector.getContacts();
        await answerStream(3, [
          _contactFrame(0x11, 'Alpha'),
          _contactFrame(0x22, 'Bravo'),
          _contactFrame(0x33, 'Charlie'),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(connector.contactSyncShortfall, isNull);
        expect(connector.contactSyncDecisionPending, isFalse);
        expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      },
    );

    test('the banner cannot be dismissed while a decision is open', () async {
      await threeShortSyncs();
      connector.dismissContactSyncShortfall();

      expect(connector.contactSyncShortfall, isNotNull);
    });

    test('the give-up wait is pinned', () {
      expect(
        MeshCoreConnector.contactRecoveryMaxWait,
        const Duration(minutes: 2),
      );
    });

    test('recovery waits for the radio to go quiet', () async {
      var now = DateTime.utc(2026, 10, 2, 6);
      connector.contactSyncClock = () => now;
      connector.contactRecoverySettle = const Duration(milliseconds: 10);
      seedSaved();
      await fullSync(declared: 350, streamed: [_contactFrame(0x11, 'Alpha')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(contactRequests(), 1, reason: 'radio not quiet yet');

      now = now.add(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(contactRequests(), 2);
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

    test('a stream that never ends is ended at 30 s without pruning', () async {
      seedSaved();
      await connector.getContacts();
      connector.handleFrameForTest(_start(3));
      connector.handleFrameForTest(_contactFrame(0x11, 'Alpha'));
      await connector.getContacts(since: 5, preserveExisting: true);

      now = now.add(const Duration(seconds: 29));
      connector.checkStaleContactRequest();
      expect(connector.isLoadingContacts, isTrue, reason: 'live at 29 s');

      now = now.add(const Duration(seconds: 2));
      connector.checkStaleContactRequest();
      await Future<void>.delayed(Duration.zero);

      expect(names(), {'Alpha', 'Bravo', 'Charlie'});
      expect(contactRequests(), 2, reason: 'the queued request ran');
      expect(sent.last.length, 5, reason: 'the queued incremental request');
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
