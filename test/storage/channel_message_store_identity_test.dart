import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1063 (Epic B of #1061): slot reassignment must not move history between
/// channel identities. Persisted history is PSK-keyed (#194); the remnants a
/// reassignment clears are the LEGACY slot-index keys. Whether the outgoing
/// occupant's PSK-keyed history stays is the full sync's call (#1128): it is
/// deleted when no channel on the radio shows it, never kept hidden.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  const pskA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const pskB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

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

  ChannelMessageStore store({String? psk}) => ChannelMessageStore()
    ..setPublicKeyHex = 'd' * 20
    ..channelPskResolver = (_) => psk;

  test('clearLegacySlotHistory purges the legacy slot keys', () async {
    // Pre-#194 remnants: device-scoped index key and the unscoped one.
    await blobs.write(
      'channel_messages_dddddddddd0',
      ChannelMessageStore.encodeHistoryForTest([chan(1)]),
    );
    await blobs.write(
      'channel_messages_0',
      ChannelMessageStore.encodeHistoryForTest([chan(2)]),
    );

    await store(psk: pskA).clearLegacySlotHistory(0);

    expect(
      await blobs.readWithPrefsFallback('channel_messages_dddddddddd0'),
      isNull,
    );
    expect(await blobs.readWithPrefsFallback('channel_messages_0'), isNull);
  });

  test('clearLegacySlotHistory keeps the PSK-keyed history', () async {
    final s = store(psk: pskA);
    await s.saveChannelMessages(0, [chan(1), chan(2)]);

    await s.clearLegacySlotHistory(0);

    final loaded = await s.loadChannelMessages(0);
    expect(loaded.map((m) => m.messageId), ['id1', 'id2']);
  });

  test('after a reassignment clear, the new occupant does not adopt the old '
      'occupant\'s legacy slot history', () async {
    // Old occupant A left pre-#194 history under the slot-index key.
    await blobs.write(
      'channel_messages_dddddddddd0',
      ChannelMessageStore.encodeHistoryForTest([chan(1, text: 'old-A')]),
    );

    // Slot 0 is reassigned to channel B: the connector purges the legacy
    // slot keys (setChannel, #1063).
    await store(psk: pskB).clearLegacySlotHistory(0);

    // Channel B's first load must not inherit A's messages via the one-time
    // slot-index adoption.
    expect(await store(psk: pskB).loadChannelMessages(0), isEmpty);
  });

  test('clearing a slot\'s legacy keys leaves PSK-keyed history for the sync '
      'to judge', () async {
    // Channel A lives in slot 0 with PSK-keyed history.
    final asA = store(psk: pskA);
    await asA.saveChannelMessages(0, [chan(1, text: 'kept')]);

    // Slot 0 is reassigned to channel B. Firmware may have moved A rather
    // than overwritten it (#1896), so the write alone must not delete A's.
    await store(psk: pskB).clearLegacySlotHistory(0);
    await store(psk: pskB).saveChannelMessages(0, [chan(9, text: 'b-msg')]);

    final loaded = await store(psk: pskA).loadChannelMessages(5);
    expect(loaded.single.text, 'kept');
  });

  group('#1128 move, delete and purge by key', () {
    test(
      'a move lands every message under the new key and empties the old',
      () async {
        await store(psk: pskA).saveChannelMessages(0, [chan(1), chan(2)]);

        expect(await store().moveChannelHistory(pskA, pskB), 2);

        expect(await store(psk: pskB).loadChannelMessages(0), hasLength(2));
        expect(await store(psk: pskA).loadChannelMessages(0), isEmpty);
        expect(
          await blobs.readWithPrefsFallback(
            'channel_messages_ddddddddddpsk_$pskA',
          ),
          isNull,
        );
      },
    );

    test('a move merges into what the new key already holds, keeping its '
        'copy of a shared message', () async {
      await store(
        psk: pskA,
      ).saveChannelMessages(0, [chan(1, text: 'old copy'), chan(2)]);
      await store(
        psk: pskB,
      ).saveChannelMessages(0, [chan(1, text: 'new copy')]);

      expect(await store().moveChannelHistory(pskA, pskB), 1);

      final moved = await store(psk: pskB).loadChannelMessages(0);
      expect(moved.map((m) => m.text), unorderedEquals(['new copy', 'm2']));
    });

    test('the move\'s delete takes only the rows it copied', () async {
      const key = 'channel_messages_ddddddddddpsk_$pskA';
      await store(psk: pskA).saveChannelMessages(0, [chan(1), chan(2)]);

      await blobs.deleteMessageRowsIn(key, ['id:id1']);

      expect(await blobs.messageMergeKeys(key), {'id:id2'});
    });

    test('a move reads an old key still on the blob', () async {
      await blobs.write(
        'channel_messages_ddddddddddpsk_$pskA',
        ChannelMessageStore.encodeHistoryForTest([chan(1), chan(2), chan(3)]),
      );

      expect(await store().moveChannelHistory(pskA, pskB), 3);
      expect(await store(psk: pskB).loadChannelMessages(0), hasLength(3));
      expect(await store(psk: pskA).loadChannelMessages(0), isEmpty);
    });

    test('a move that cannot read the old key changes neither key', () async {
      await blobs.write('channel_messages_ddddddddddpsk_$pskA', 'not json');

      expect(await store().moveChannelHistory(pskA, pskB), isNull);
      expect(
        await blobs.readWithPrefsFallback(
          'channel_messages_ddddddddddpsk_$pskA',
        ),
        'not json',
      );
      expect(await store(psk: pskB).loadChannelMessages(0), isEmpty);
    });

    test(
      'deleteChannelHistory removes rows and blob for that key only',
      () async {
        await store(psk: pskA).saveChannelMessages(0, [chan(1)]);
        await store(psk: pskB).saveChannelMessages(1, [chan(2)]);

        await store().deleteChannelHistory(pskA);

        expect(await store(psk: pskA).loadChannelMessages(0), isEmpty);
        expect(await store(psk: pskB).loadChannelMessages(1), hasLength(1));
      },
    );

    test('the purge deletes keys no radio channel shows and empty-slot '
        'legacy keys, and nothing else', () async {
      const pskC = 'cccccccccccccccccccccccccccccccc';
      await store(psk: pskA).saveChannelMessages(0, [chan(1)]);
      await store(psk: pskB).saveChannelMessages(1, [chan(2)]);
      await blobs.write(
        'channel_messages_ddddddddddpsk_$pskC',
        ChannelMessageStore.encodeHistoryForTest([chan(3)]),
      );
      // Legacy slot keys: slot 0 holds a channel, slot 7 holds nothing.
      for (final slot in [0, 7]) {
        await blobs.write(
          'channel_messages_dddddddddd$slot',
          ChannelMessageStore.encodeHistoryForTest([chan(4)]),
        );
      }
      // Another radio's history is never this radio's to judge.
      await (ChannelMessageStore()
            ..setPublicKeyHex = 'e' * 20
            ..channelPskResolver = (_) => pskB)
          .saveChannelMessages(0, [chan(5)]);

      final deleted = await store().purgeHistoryNotOnRadio(
        radioPskHex: {pskA},
        occupiedSlots: {0},
      );

      expect(
        deleted,
        unorderedEquals([
          'channel_messages_ddddddddddpsk_$pskB',
          'channel_messages_ddddddddddpsk_$pskC',
          'channel_messages_dddddddddd7',
        ]),
      );
      expect(await store(psk: pskA).loadChannelMessages(0), hasLength(1));
      expect(
        await blobs.readWithPrefsFallback('channel_messages_dddddddddd0'),
        isNotNull,
      );
      expect(
        await (ChannelMessageStore()
              ..setPublicKeyHex = 'e' * 20
              ..channelPskResolver = (_) => pskB)
            .loadChannelMessages(0),
        hasLength(1),
      );
    });

    test('the purge deletes nothing for a radio with no channels', () async {
      await store(psk: pskA).saveChannelMessages(0, [chan(1)]);

      expect(
        await store().purgeHistoryNotOnRadio(
          radioPskHex: {},
          occupiedSlots: {},
        ),
        isEmpty,
      );
      expect(await store(psk: pskA).loadChannelMessages(0), hasLength(1));
    });
  });

  test('clearChannelMessages (true delete) removes the PSK-keyed history '
      'and the legacy index key', () async {
    final s = store(psk: pskA);
    await s.saveChannelMessages(0, [chan(1)]);
    await blobs.write(
      'channel_messages_dddddddddd0',
      ChannelMessageStore.encodeHistoryForTest([chan(2)]),
    );

    await s.clearChannelMessages(0);

    expect(await s.loadChannelMessages(0), isEmpty);
    expect(
      await blobs.readWithPrefsFallback('channel_messages_dddddddddd0'),
      isNull,
    );
  });
}
