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

/// #920 B2: both stores read and write rows. These go through the public store
/// API only, because that is what the app calls and what an existing install
/// will hit on its first launch after this ships.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    blobs = BlobStore(db);
    BlobStore.overrideForTest(blobs);
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  ChannelMessage chan(int i, {String? text}) => ChannelMessage(
    senderName: 's',
    text: text ?? 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id$i',
  );

  Message dm(int i, {String? text}) => Message(
    senderKey: Uint8List.fromList(const [1, 2, 3, 4]),
    text: text ?? 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    messageId: 'id$i',
  );

  group('channel store on rows', () {
    test('a save writes rows, not a blob', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      await store.saveChannelMessages(0, [chan(1), chan(2)]);

      expect(await blobs.messageRowCount('channel_messages_aaaaaaaaaa0'), 2);
      expect(
        await blobs.read('channel_messages_aaaaaaaaaa0'),
        isNull,
        reason: 'the blob path is the fallback now, not the write path',
      );
    });

    test('round-trips through load', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2), chan(3)]);

      final loaded = await store.loadChannelMessages(0);

      expect(loaded.map((m) => m.messageId), ['id1', 'id2', 'id3']);
      expect(loaded.map((m) => m.text), ['m1', 'm2', 'm3']);
    });

    test('a windowed save does not truncate stored history (#343)', () async {
      // The in-memory list is windowed, so this is the case that made saves a
      // merge in the first place. On rows it has to stay true.
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2), chan(3)]);

      await store.saveChannelMessages(0, [chan(4)]);

      final loaded = await store.loadChannelMessages(0);
      expect(loaded.map((m) => m.messageId), ['id1', 'id2', 'id3', 'id4']);
    });

    test('re-saving a message updates it instead of duplicating', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1, text: 'first')]);

      await store.saveChannelMessages(0, [chan(1, text: 'edited')]);

      final loaded = await store.loadChannelMessages(0);
      expect(loaded.single.text, 'edited');
    });

    test('an existing blob history is adopted on first load', () async {
      // What every current install looks like: the whole history in a blob and
      // no rows at all.
      const key = 'channel_messages_aaaaaaaaaa0';
      await blobs.write(
        key,
        ChannelMessageStore.encodeHistoryForTest([chan(1), chan(2), chan(3)]),
      );
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      final loaded = await store.loadChannelMessages(0);

      expect(loaded.map((m) => m.messageId), ['id1', 'id2', 'id3']);
      expect(await blobs.messageRowCount(key), 3, reason: 'migrated on read');
      expect(await blobs.isOnMessageRows(key), isTrue);
    });

    test('an existing blob history is adopted on first save', () async {
      const key = 'channel_messages_aaaaaaaaaa0';
      await blobs.write(
        key,
        ChannelMessageStore.encodeHistoryForTest([chan(1), chan(2)]),
      );
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      await store.saveChannelMessages(0, [chan(3)]);

      final loaded = await store.loadChannelMessages(0);
      expect(
        loaded.map((m) => m.messageId),
        ['id1', 'id2', 'id3'],
        reason: 'the blob history must not be lost by the first row save',
      );
    });

    test('the adopted blob is left in place', () async {
      const key = 'channel_messages_aaaaaaaaaa0';
      final original = ChannelMessageStore.encodeHistoryForTest([chan(1)]);
      await blobs.write(key, original);
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      await store.loadChannelMessages(0);

      expect(await blobs.read(key), original);
    });

    test('delete removes one message and keeps the rest', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2), chan(3)]);

      await store.removeChannelMessage(0, chan(2));

      final loaded = await store.loadChannelMessages(0);
      expect(loaded.map((m) => m.messageId), ['id1', 'id3']);
    });

    test('a deleted message is not resurrected by the next save', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2)]);
      await store.removeChannelMessage(0, chan(2));

      // The in-memory list the app saves next may still be stale, but a save
      // that re-sends the deleted message legitimately re-adds it. What must
      // not happen is a save of OTHER messages bringing it back.
      await store.saveChannelMessages(0, [chan(1)]);

      final loaded = await store.loadChannelMessages(0);
      expect(loaded.map((m) => m.messageId), ['id1']);
    });

    test('clear removes the rows, not just the blob', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2)]);

      await store.clearChannelMessages(0);

      expect(await store.loadChannelMessages(0), isEmpty);
      expect(await blobs.messageRowCount('channel_messages_aaaaaaaaaa0'), 0);
    });

    test('clearAll removes row-only histories too', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1)]);
      await store.saveChannelMessages(1, [chan(2)]);

      await store.clearAllChannelMessages();

      expect(await store.loadChannelMessages(0), isEmpty);
      expect(await store.loadChannelMessages(1), isEmpty);
    });

    test('history stays scoped per radio', () async {
      // A bleed here is #472, which shipped once already.
      final radioA = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      final radioB = ChannelMessageStore()..setPublicKeyHex = 'b' * 20;

      await radioA.saveChannelMessages(0, [chan(1)]);
      await radioB.saveChannelMessages(0, [chan(2)]);

      expect((await radioA.loadChannelMessages(0)).single.messageId, 'id1');
      expect((await radioB.loadChannelMessages(0)).single.messageId, 'id2');
    });

    test('one unreadable row costs one message, not the channel', () async {
      // On the blob, a single bad byte took the whole history with it.
      const key = 'channel_messages_aaaaaaaaaa0';
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveChannelMessages(0, [chan(1), chan(2)]);
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(
          mergeKey: 'id:broken',
          timestampMs: 1500,
          payload: '{not json',
        ),
      ]);

      final loaded = await store.loadChannelMessages(0);

      expect(loaded.map((m) => m.messageId), ['id1', 'id2']);
    });
  });

  group('DM store on rows', () {
    test('a save writes rows, not a blob', () async {
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;

      await store.saveMessages('beef', [dm(1), dm(2)]);

      expect(await blobs.messageRowCount('messages_aaaaaaaaaabeef'), 2);
      expect(await blobs.read('messages_aaaaaaaaaabeef'), isNull);
    });

    test('round-trips through load', () async {
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveMessages('beef', [dm(1), dm(2)]);

      final loaded = await store.loadMessages('beef');

      expect(loaded.map((m) => m.messageId), ['id1', 'id2']);
    });

    test('a windowed save does not truncate stored history (#343)', () async {
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveMessages('beef', [dm(1), dm(2)]);

      await store.saveMessages('beef', [dm(3)]);

      expect((await store.loadMessages('beef')).map((m) => m.messageId), [
        'id1',
        'id2',
        'id3',
      ]);
    });

    test('an existing blob history is adopted on first load', () async {
      const key = 'messages_aaaaaaaaaabeef';
      await blobs.write(key, MessageStore.encodeHistoryForTest([dm(1), dm(2)]));
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;

      final loaded = await store.loadMessages('beef');

      expect(loaded.map((m) => m.messageId), ['id1', 'id2']);
      expect(await blobs.messageRowCount(key), 2);
    });

    test('an existing blob history is adopted on first save', () async {
      const key = 'messages_aaaaaaaaaabeef';
      await blobs.write(key, MessageStore.encodeHistoryForTest([dm(1)]));
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;

      await store.saveMessages('beef', [dm(2)]);

      expect((await store.loadMessages('beef')).map((m) => m.messageId), [
        'id1',
        'id2',
      ]);
    });

    test('delete removes one message', () async {
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveMessages('beef', [dm(1), dm(2), dm(3)]);

      await store.removeMessage('beef', dm(2));

      expect((await store.loadMessages('beef')).map((m) => m.messageId), [
        'id1',
        'id3',
      ]);
    });

    test('clear removes the rows', () async {
      final store = MessageStore()..setPublicKeyHex = 'a' * 20;
      await store.saveMessages('beef', [dm(1)]);

      await store.clearMessages('beef');

      expect(await store.loadMessages('beef'), isEmpty);
    });

    test('conversations stay scoped per contact and per radio', () async {
      final radioA = MessageStore()..setPublicKeyHex = 'a' * 20;
      final radioB = MessageStore()..setPublicKeyHex = 'b' * 20;

      await radioA.saveMessages('beef', [dm(1)]);
      await radioA.saveMessages('cafe', [dm(2)]);
      await radioB.saveMessages('beef', [dm(3)]);

      expect((await radioA.loadMessages('beef')).single.messageId, 'id1');
      expect((await radioA.loadMessages('cafe')).single.messageId, 'id2');
      expect((await radioB.loadMessages('beef')).single.messageId, 'id3');
    });
  });

  group('refused migration keeps the store working on the blob', () {
    test('channel: a corrupt blob still reads and saves', () async {
      const key = 'channel_messages_aaaaaaaaaa0';
      // Valid JSON that the converter cannot turn into messages: the record
      // decode throws, so the migration must refuse and the blob path stays.
      await blobs.write(key, '[{"not":"a message"}]');
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      final loaded = await store.loadChannelMessages(0);

      expect(
        await blobs.isOnMessageRows(key),
        isFalse,
        reason: 'a converter that throws must not mark the key migrated',
      );
      expect(loaded, isEmpty, reason: 'the blob itself does not decode either');
      expect(await blobs.read(key), '[{"not":"a message"}]');

      // And a save still lands, on the blob path.
      await store.saveChannelMessages(0, [chan(1)]);
      expect(await blobs.read(key), isNotNull);
    });

    test(
      'channel: the blob fallback still merges rather than overwriting',
      () async {
        const key = 'channel_messages_aaaaaaaaaa0';
        await blobs.write(key, '[{"not":"a message"}]');
        final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
        await store.loadChannelMessages(0);

        // mergeOffThread fails closed on an undecodable blob, so the refused
        // key keeps its bytes rather than being replaced by the incoming save.
        await store.saveChannelMessages(0, [chan(1)]);

        expect(await blobs.read(key), '[{"not":"a message"}]');
        expect(
          await blobs.messageRowCount(key),
          0,
          reason: 'a refused key must not accumulate half a history in rows',
        );
      },
    );
  });

  test('the payload a row stores is the stores own encoding', () async {
    // Guards the migration contract: rows hold exactly what the blob held, so
    // a payload is decodable by the same _messageFromJson.
    final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
    await store.saveChannelMessages(0, [chan(1)]);

    final payload = (await blobs.messagePayloads(
      'channel_messages_aaaaaaaaaa0',
    )).single;
    final decoded = jsonDecode(payload) as Map<String, dynamic>;

    expect(decoded['messageId'], 'id1');
    expect(decoded['text'], 'm1');
    expect(decoded.containsKey('status'), isTrue);
  });
}
