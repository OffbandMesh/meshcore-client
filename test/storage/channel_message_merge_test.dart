import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #343: saving a windowed in-memory list must not truncate the persisted
/// history. The store keeps full history; deletion is explicit.
void main() {
  late OffbandDatabase db;
  late ChannelMessageStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    store = ChannelMessageStore();
    store.setPublicKeyHex = 'a' * 20;
    // No PSK resolver -> uses the slot-index key, which is fine for the test.
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  ChannelMessage msg(int i) => ChannelMessage(
    senderName: 's',
    text: 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id$i',
  );

  test('saving a 200-window does not truncate a 250-message history', () async {
    // Seed 250 messages, as if a full history were persisted.
    await store.saveChannelMessages(0, [for (var i = 0; i < 250; i++) msg(i)]);
    expect((await store.loadChannelMessages(0)).length, 250);

    // The app now saves only the most-recent 200 (its in-memory window).
    final window = [for (var i = 50; i < 250; i++) msg(i)];
    await store.saveChannelMessages(0, window);

    // Full history must survive: the older 50 are still there.
    final all = await store.loadChannelMessages(0);
    expect(all.length, 250, reason: 'the older 50 must not be dropped');
    expect(all.first.text, 'm0');
    expect(all.last.text, 'm249');
  });

  test('a new message appends without dropping old history', () async {
    await store.saveChannelMessages(0, [for (var i = 0; i < 10; i++) msg(i)]);
    await store.saveChannelMessages(0, [msg(10)]);
    final all = await store.loadChannelMessages(0);
    expect(all.length, 11);
    expect(all.last.text, 'm10');
  });

  test('an edit to a message is captured, not duplicated', () async {
    await store.saveChannelMessages(0, [msg(1)]);
    final edited = ChannelMessage(
      senderName: 's',
      text: 'm1',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1001),
      isOutgoing: false,
      channelIndex: 0,
      messageId: 'id1',
      reactions: {'thumbsup': 2},
    );
    await store.saveChannelMessages(0, [edited]);
    final all = await store.loadChannelMessages(0);
    expect(all, hasLength(1));
    expect(all.single.reactions['thumbsup'], 2);
  });

  test('deleting a message does NOT resurrect it on the next save', () async {
    await store.saveChannelMessages(0, [for (var i = 0; i < 5; i++) msg(i)]);

    // Delete via the explicit path.
    await store.removeChannelMessage(0, msg(2));
    expect(
      (await store.loadChannelMessages(0)).map((m) => m.text),
      isNot(contains('m2')),
    );

    // A later save of the remaining in-memory list must not bring it back.
    final remaining = [
      for (var i = 0; i < 5; i++)
        if (i != 2) msg(i),
    ];
    await store.saveChannelMessages(0, remaining);

    final all = await store.loadChannelMessages(0);
    expect(all.map((m) => m.text), isNot(contains('m2')));
    expect(all, hasLength(4));
  });
}
