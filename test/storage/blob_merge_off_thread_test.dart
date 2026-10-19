import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/message_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #919: the blob read-modify-write moved off the UI isolate. These tests pin
/// the two things that must not change with it: the merge is semantically what
/// it was, and a blob that cannot be decoded is never overwritten.
void main() {
  late OffbandDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  ChannelMessage msg(int i, {String? text}) => ChannelMessage(
    senderName: 's',
    text: text ?? 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id$i',
  );

  // Fixtures go through the store's OWN encoder rather than a hand-written map.
  // A hand-rolled fixture silently rots the moment a non-null field is added to
  // the schema, which is exactly how the first run of this test failed.
  Future<String> encodeVia(List<ChannelMessage> ms) async {
    final fixtureDb = OffbandDatabase(NativeDatabase.memory());
    final previous = BlobStore.instance;
    BlobStore.overrideForTest(BlobStore(fixtureDb));
    try {
      final store = ChannelMessageStore()..setPublicKeyHex = 'f' * 20;
      await store.saveChannelMessages(0, ms);
      final keys = await BlobStore.instance.keysWithPrefix('channel_messages_');
      return (await BlobStore.instance.read(keys.single))!;
    } finally {
      BlobStore.overrideForTest(previous);
      await fixtureDb.close();
    }
  }

  group('mergeChannelHistoryJson', () {
    test('adds incoming messages to the stored history', () async {
      final stored = await encodeVia([msg(1), msg(2)]);
      final incoming = await encodeVia([msg(3)]);

      final out =
          jsonDecode(mergeChannelHistoryJson((stored, incoming)))
              as List<dynamic>;

      expect(out.length, 3);
      expect(
        out.map((e) => (e as Map<String, dynamic>)['messageId']),
        containsAll(['id1', 'id2', 'id3']),
      );
    });

    test('incoming wins on the same id, so edits are captured', () async {
      final stored = await encodeVia([msg(1, text: 'original')]);
      final incoming = await encodeVia([msg(1, text: 'edited')]);

      final out =
          jsonDecode(mergeChannelHistoryJson((stored, incoming)))
              as List<dynamic>;

      expect(
        out.length,
        1,
        reason: 'same messageId must upsert, not duplicate',
      );
      expect((out.single as Map<String, dynamic>)['text'], 'edited');
    });

    test('result is sorted by timestamp regardless of input order', () async {
      final stored = await encodeVia([msg(9), msg(3)]);
      final incoming = await encodeVia([msg(5)]);

      final out =
          jsonDecode(mergeChannelHistoryJson((stored, incoming)))
              as List<dynamic>;
      final stamps = out
          .map((e) => (e as Map<String, dynamic>)['timestamp'] as int)
          .toList();

      expect(stamps, [...stamps]..sort());
    });

    test(
      'an empty or absent stored blob merges into just the incoming',
      () async {
        final incoming = await encodeVia([msg(1)]);

        for (final stored in <String?>[null, '']) {
          final out =
              jsonDecode(mergeChannelHistoryJson((stored, incoming)))
                  as List<dynamic>;
          expect(out.length, 1, reason: 'stored=$stored');
        }
      },
    );

    test(
      'THROWS on an undecodable stored blob rather than truncating',
      () async {
        final incoming = await encodeVia([msg(1)]);

        // The whole point: swallowing this would merge into an empty base and
        // silently replace real history with one message.
        expect(
          () => mergeChannelHistoryJson(('{not json at all', incoming)),
          throwsA(anything),
        );
      },
    );
  });

  Message dm(int i, {String? text}) => Message(
    senderKey: Uint8List.fromList(const [1, 2, 3, 4]),
    text: text ?? 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    messageId: 'id$i',
  );

  Future<String> encodeDmVia(List<Message> ms) async {
    final fixtureDb = OffbandDatabase(NativeDatabase.memory());
    final previous = BlobStore.instance;
    BlobStore.overrideForTest(BlobStore(fixtureDb));
    try {
      final store = MessageStore()..setPublicKeyHex = 'f' * 20;
      await store.saveMessages('abcd', ms);
      final keys = await BlobStore.instance.keysWithPrefix('messages_');
      return (await BlobStore.instance.read(keys.single))!;
    } finally {
      BlobStore.overrideForTest(previous);
      await fixtureDb.close();
    }
  }

  group('mergeDmHistoryJson', () {
    test('adds incoming messages to the stored history', () async {
      final stored = await encodeDmVia([dm(1), dm(2)]);
      final incoming = await encodeDmVia([dm(3)]);

      final out =
          jsonDecode(mergeDmHistoryJson((stored, incoming))) as List<dynamic>;

      expect(out.length, 3);
      expect(
        out.map((e) => (e as Map<String, dynamic>)['messageId']),
        containsAll(['id1', 'id2', 'id3']),
      );
    });

    test('incoming wins on the same id, so a status change lands', () async {
      final stored = await encodeDmVia([dm(1, text: 'original')]);
      final incoming = await encodeDmVia([dm(1, text: 'edited')]);

      final out =
          jsonDecode(mergeDmHistoryJson((stored, incoming))) as List<dynamic>;

      expect(
        out.length,
        1,
        reason: 'same messageId must upsert, not duplicate',
      );
      expect((out.single as Map<String, dynamic>)['text'], 'edited');
    });

    test('result is sorted by timestamp regardless of input order', () async {
      final stored = await encodeDmVia([dm(9), dm(3)]);
      final incoming = await encodeDmVia([dm(5)]);

      final out =
          jsonDecode(mergeDmHistoryJson((stored, incoming))) as List<dynamic>;
      final stamps = out
          .map((e) => (e as Map<String, dynamic>)['timestamp'] as int)
          .toList();

      expect(stamps, [...stamps]..sort());
    });

    test(
      'an empty or absent stored blob merges into just the incoming',
      () async {
        final incoming = await encodeDmVia([dm(1)]);

        for (final stored in <String?>[null, '']) {
          final out =
              jsonDecode(mergeDmHistoryJson((stored, incoming)))
                  as List<dynamic>;
          expect(out.length, 1, reason: 'stored=$stored');
        }
      },
    );

    test(
      'THROWS on an undecodable stored blob rather than truncating',
      () async {
        final incoming = await encodeDmVia([dm(1)]);

        expect(
          () => mergeDmHistoryJson(('{not json at all', incoming)),
          throwsA(anything),
        );
      },
    );

    test(
      'a full DM save round trip through mergeOffThread keeps both',
      () async {
        final store = MessageStore()..setPublicKeyHex = 'a' * 20;
        await store.saveMessages('beef', [dm(1)]);
        await store.saveMessages('beef', [dm(2)]);

        final loaded = await store.loadMessages('beef');
        expect(
          loaded.map((m) => m.messageId),
          ['id1', 'id2'],
          reason: 'the second save must merge, not overwrite (#343)',
        );
      },
    );
  });

  group('BlobStore.mergeOffThread', () {
    test('writes the merged result', () async {
      final blobs = BlobStore.instance;
      await blobs.write('k', await encodeVia([msg(1)]));

      final wrote = await blobs.mergeOffThread(
        'k',
        await encodeVia([msg(2)]),
        mergeChannelHistoryJson,
      );

      expect(wrote, isTrue);
      final out = jsonDecode((await blobs.read('k'))!) as List<dynamic>;
      expect(out.length, 2);
    });

    test(
      'FAILS CLOSED on a corrupt stored blob: returns false and leaves it byte-identical',
      () async {
        final blobs = BlobStore.instance;
        const corrupt = '{not json at all';
        await blobs.write('k', corrupt);

        final wrote = await blobs.mergeOffThread(
          'k',
          await encodeVia([msg(1)]),
          mergeChannelHistoryJson,
        );

        expect(
          wrote,
          isFalse,
          reason: 'a failed merge must not report success',
        );
        expect(
          await blobs.read('k'),
          corrupt,
          reason: 'the unreadable blob must survive untouched, not be replaced',
        );
      },
    );

    test('a merge returning null leaves the key untouched', () async {
      final blobs = BlobStore.instance;
      await blobs.write('k', 'original');

      final wrote = await blobs.mergeOffThread('k', 'x', _alwaysNull);

      expect(wrote, isFalse);
      expect(await blobs.read('k'), 'original');
    });

    test('concurrent merges on one key do not clobber each other', () async {
      final blobs = BlobStore.instance;
      await blobs.write('k', await encodeVia([msg(0)]));

      // Fired together: without the per-key serialisation one read-modify-write
      // would overwrite the other and a message would vanish.
      await Future.wait([
        blobs.mergeOffThread(
          'k',
          await encodeVia([msg(1)]),
          mergeChannelHistoryJson,
        ),
        blobs.mergeOffThread(
          'k',
          await encodeVia([msg(2)]),
          mergeChannelHistoryJson,
        ),
        blobs.mergeOffThread(
          'k',
          await encodeVia([msg(3)]),
          mergeChannelHistoryJson,
        ),
      ]);

      final out = jsonDecode((await blobs.read('k'))!) as List<dynamic>;
      expect(
        out.length,
        4,
        reason: 'all three concurrent saves plus the original must survive',
      );
    });
  });
}

/// Top-level so `compute` can send it.
String? _alwaysNull((String?, String) input) => null;
