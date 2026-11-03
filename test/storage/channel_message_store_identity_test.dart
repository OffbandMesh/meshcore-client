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
/// reassignment has to deal with are the LEGACY slot-index keys, and only
/// those - the outgoing occupant's PSK-keyed history survives so re-adding
/// that channel brings its messages back.
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

  test('the outgoing occupant\'s history survives a reassignment and comes '
      'back when the channel is re-added', () async {
    // Channel A lives in slot 0 with PSK-keyed history.
    final asA = store(psk: pskA);
    await asA.saveChannelMessages(0, [chan(1, text: 'kept')]);

    // Slot 0 is reassigned to channel B.
    await store(psk: pskB).clearLegacySlotHistory(0);
    await store(psk: pskB).saveChannelMessages(0, [chan(9, text: 'b-msg')]);

    // Channel A is re-added (any slot; identity is the PSK, not the slot).
    final loaded = await store(psk: pskA).loadChannelMessages(5);
    expect(loaded.single.text, 'kept');
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
