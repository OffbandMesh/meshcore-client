// #1163: the owner asked for a way to start fresh for one radio, channels and
// direct messages together, and for a channel clear that actually clears.
// Clear Chat used to save an emptied list; saves merge (#343), so nothing was
// deleted and the history came back on the next load.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/message_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/storage/radio_data_wipe.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _radioA = Uint8List.fromList(List<int>.generate(32, (i) => i));
const _radioAPrefix = '0001020304';
const _radioBPrefix = '6364656667';

Channel _channel(int index, String name, int seed) => Channel(
  index: index,
  name: name,
  psk: Uint8List.fromList(List<int>.generate(16, (i) => (seed + i) & 0xFF)),
);

ChannelMessage _chanMsg(String text) => ChannelMessage(
  senderName: 'X',
  text: text,
  timestamp: DateTime.fromMillisecondsSinceEpoch(5000),
  isOutgoing: false,
  status: ChannelMessageStatus.sent,
  channelIndex: 0,
);

Message _dm(String text) => Message(
  senderKey: Uint8List(32),
  text: text,
  timestamp: DateTime.fromMillisecondsSinceEpoch(5000),
  isOutgoing: false,
);

ChannelMessageStore _chanStore(String radio, Channel ch) =>
    ChannelMessageStore()
      ..setPublicKeyHex = radio
      ..channelPskResolver = ((_) => ch.pskHex);

// MessageStore takes the radio's full key and keeps its first 10 hex; a bare
// 10-hex prefix is refused and every save is skipped.
MessageStore _dmStore(String radio) =>
    MessageStore()..setPublicKeyHex = '$radio${'0' * 54}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  final alpha = _channel(0, 'Alpha', 10);
  const contactKey =
      'aa00000000000000000000000000000000000000000000000000000000000000';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<List<String>> chanTexts(String radio) async => (await _chanStore(
    radio,
    alpha,
  ).loadChannelMessages(0)).map((m) => m.text).toList();
  Future<List<String>> dmTexts(String radio) async => (await _dmStore(
    radio,
  ).loadMessages(contactKey)).map((m) => m.text).toList();

  test("the per-radio wipe removes this radio's channel and DM history, and "
      "nothing of any other radio's", () async {
    for (final radio in [_radioAPrefix, _radioBPrefix]) {
      await _chanStore(radio, alpha).saveChannelMessages(0, [_chanMsg(radio)]);
      await _dmStore(radio).saveMessages(contactKey, [_dm(radio)]);
    }
    await BlobStore.instance.write('contacts$_radioAPrefix', '[]');
    expect(await dmTexts(_radioAPrefix), [_radioAPrefix]);
    expect(await dmTexts(_radioBPrefix), [_radioBPrefix]);

    await wipeRadioMessageHistory(_radioAPrefix);

    expect(await chanTexts(_radioAPrefix), isEmpty);
    expect(await dmTexts(_radioAPrefix), isEmpty);
    expect(await chanTexts(_radioBPrefix), [_radioBPrefix]);
    expect(await dmTexts(_radioBPrefix), [_radioBPrefix]);
    expect(
      await BlobStore.instance.read('contacts$_radioAPrefix'),
      '[]',
      reason: 'contacts are not message history and stay',
    );
  });

  test('the per-radio wipe refuses anything but a 10-hex radio prefix', () {
    expect(() => wipeRadioMessageHistory(''), throwsArgumentError);
    expect(() => wipeRadioMessageHistory('0001'), throwsArgumentError);
  });

  group('connector', () {
    late MeshCoreConnector c;

    setUp(() {
      c = MeshCoreConnector();
      c.setConnectedForTest();
      c.setSelfPublicKeyForTest(_radioA);
      c.wireMessageStoreForTest();
      c.seedCachedChannelsForTest([alpha]);
    });

    test(
      'deleting message history for this radio empties the screen too',
      () async {
        await _chanStore(
          _radioAPrefix,
          alpha,
        ).saveChannelMessages(0, [_chanMsg('old')]);
        await c.loadAllChannelMessages(maxChannels: 1);
        expect(c.channelMessagesForTest[0], isNotEmpty);

        expect(await c.deleteMessageHistoryForThisRadio(), isNull);

        expect(c.channelMessagesForTest, isEmpty);
        expect(await chanTexts(_radioAPrefix), isEmpty);
      },
    );

    test(
      'deleting message history with no radio connected is refused',
      () async {
        final idle = MeshCoreConnector();

        expect(
          await idle.deleteMessageHistoryForThisRadio(),
          HistoryWipeRefusal.notConnected,
        );
      },
    );

    test('Clear Chat on a channel deletes its stored history', () async {
      await _chanStore(
        _radioAPrefix,
        alpha,
      ).saveChannelMessages(0, [_chanMsg('old')]);
      await c.loadAllChannelMessages(maxChannels: 1);

      await c.clearChannelHistory(alpha);
      await c.loadAllChannelMessages(maxChannels: 1);

      expect(
        c.channelMessagesForTest[0] ?? const <ChannelMessage>[],
        isEmpty,
        reason: 'the bug: the history came back on the next load',
      );
      expect(await chanTexts(_radioAPrefix), isEmpty);
    });

    test('Clear Chat on a contact deletes the stored conversation', () async {
      await _dmStore(_radioAPrefix).saveMessages(contactKey, [_dm('old')]);
      expect(await dmTexts(_radioAPrefix), ['old']);
      final contact = Contact(
        publicKey: Uint8List.fromList(
          List<int>.generate(32, (i) => i == 0 ? 0xAA : 0),
        ),
        receivedName: 'Friend',
        type: 1,
        pathLength: -1,
        path: Uint8List(0),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await c.clearMessagesForContact(contact);

      expect(await dmTexts(_radioAPrefix), isEmpty);
    });
  });
}
