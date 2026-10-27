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

/// #919: the explicit delete path rewrites the whole blob too, so it moved off
/// the UI isolate with the save path. These tests pin that it still removes
/// exactly one record, never writes when there is nothing to change, and never
/// replaces a blob it could not read.
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

  ChannelMessage msg(int i) => ChannelMessage(
    senderName: 's',
    text: 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id$i',
  );

  Message dm(int i) => Message(
    senderKey: Uint8List.fromList(const [1, 2, 3, 4]),
    text: 'm$i',
    timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + i),
    isOutgoing: false,
    messageId: 'id$i',
  );

  // Fixtures go through the store's own encoder rather than a hand-written map,
  // which silently rots the moment a non-null field is added to the schema.
  // Saves write rows now (#920), so this calls the encoder directly.
  Future<String> encodeVia(List<ChannelMessage> ms) async =>
      ChannelMessageStore.encodeHistoryForTest(ms);

  group('dropFromChannelHistoryJson', () {
    test('drops only the target and keeps the rest', () async {
      final blobs = BlobStore.instance;
      await blobs.write('k', await encodeVia([msg(1), msg(2), msg(3)]));

      final wrote = await blobs.mergeOffThread(
        'k',
        'id:id2',
        dropFromChannelHistoryJson,
      );

      expect(wrote, isTrue);
      final out = jsonDecode((await blobs.read('k'))!) as List<dynamic>;
      expect(out.map((e) => (e as Map<String, dynamic>)['messageId']), [
        'id1',
        'id3',
      ]);
    });

    test('a target that is not present writes nothing at all', () async {
      final blobs = BlobStore.instance;
      final original = await encodeVia([msg(1)]);
      await blobs.write('k', original);

      final wrote = await blobs.mergeOffThread(
        'k',
        'id:nope',
        dropFromChannelHistoryJson,
      );

      expect(
        wrote,
        isFalse,
        reason:
            'rewriting megabytes to change nothing is the cost #919 exists '
            'to remove',
      );
      expect(await blobs.read('k'), original);
    });

    test('a corrupt blob survives a delete untouched', () async {
      final blobs = BlobStore.instance;
      const corrupt = '{not json at all';
      await blobs.write('k', corrupt);

      final wrote = await blobs.mergeOffThread(
        'k',
        'id:id1',
        dropFromChannelHistoryJson,
      );

      expect(wrote, isFalse);
      expect(await blobs.read('k'), corrupt);
    });

    test('an absent blob is a no-op, not an empty write', () async {
      final blobs = BlobStore.instance;

      final wrote = await blobs.mergeOffThread(
        'missing',
        'id:id1',
        dropFromChannelHistoryJson,
      );

      expect(wrote, isFalse);
      expect(await blobs.read('missing'), isNull);
    });

    test('removeChannelMessage deletes through the store API', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'c' * 20;
      await store.saveChannelMessages(0, [msg(1), msg(2), msg(3)]);

      await store.removeChannelMessage(0, msg(2));

      final loaded = await store.loadChannelMessages(0);
      expect(loaded.map((m) => m.messageId), ['id1', 'id3']);
    });
  });

  group('dropFromDmHistoryJson', () {
    test('removeMessage deletes through the store API', () async {
      final store = MessageStore()..setPublicKeyHex = 'c' * 20;
      await store.saveMessages('cafe', [dm(1), dm(2), dm(3)]);

      await store.removeMessage('cafe', dm(2));

      final loaded = await store.loadMessages('cafe');
      expect(loaded.map((m) => m.messageId), ['id1', 'id3']);
    });

    test(
      'a delete racing a save cannot resurrect the deleted message',
      () async {
        final store = MessageStore()..setPublicKeyHex = 'd' * 20;
        await store.saveMessages('f00d', [dm(1), dm(2)]);

        // Both are read-modify-writes on one key. Before #919 the delete ran
        // outside the per-key chain, so a save landing after it could bring
        // the deleted message back.
        await Future.wait([
          store.removeMessage('f00d', dm(2)),
          store.saveMessages('f00d', [dm(3)]),
        ]);

        final loaded = await store.loadMessages('f00d');
        expect(loaded.map((m) => m.messageId), ['id1', 'id3']);
      },
    );

    test('a corrupt DM blob survives a delete untouched', () async {
      final store = MessageStore()..setPublicKeyHex = 'e' * 20;
      const corrupt = '{not json at all';
      await BlobStore.instance.write('messages_eeeeeeeeeedead', corrupt);

      await store.removeMessage('dead', dm(1));

      expect(await BlobStore.instance.read('messages_eeeeeeeeeedead'), corrupt);
    });
  });
}
