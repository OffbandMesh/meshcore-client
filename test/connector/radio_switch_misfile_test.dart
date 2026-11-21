// #1163: switching radios over Bluetooth copied the previous radio's channel
// messages into the next radio's history.
//
// #472 put the in-memory clear in _resetConnectionHandshakeState, but the
// native Bluetooth connect only ran that on the web. Radio A's messages stayed
// in memory under their slot numbers; the next message on the same slot from
// radio B saved the whole list into B's channel for that slot. The owner's
// Windows store held 2,893 such copies, each with the same receive time under
// two radios.
//
// These tests go through the real connect, not the reset, because the old #472
// test called the reset directly and passed while Bluetooth never ran it.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _channelInfoFrame(Channel ch) {
  final frame = Uint8List(50);
  frame[0] = respCodeChannelInfo;
  frame[1] = ch.index;
  final nameBytes = ch.name.codeUnits;
  for (var i = 0; i < nameBytes.length && i < 31; i++) {
    frame[2 + i] = nameBytes[i];
  }
  frame.setRange(34, 50, ch.psk);
  return frame;
}

Uint8List _channelMsgFrame({required int channelIdx, required String text}) {
  return Uint8List.fromList([
    respCodeChannelMsgRecvV3,
    0,
    0,
    0,
    channelIdx,
    1,
    txtTypePlain,
    0x40,
    0xE2,
    0x01,
    0x00,
    ...text.codeUnits,
  ]);
}

Channel _channel(int index, String name, int pskSeed) => Channel(
  index: index,
  name: name,
  psk: Uint8List.fromList(List<int>.generate(16, (i) => (pskSeed + i) & 0xFF)),
);

Future<void> _settle([int turns = 25]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final _radioA = Uint8List.fromList(List<int>.generate(32, (i) => i));
final _radioB = Uint8List.fromList(List<int>.generate(32, (i) => 99 + i));

String _hex(Uint8List key) =>
    key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OffbandDatabase db;
  late MeshCoreConnector c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    c = MeshCoreConnector();
    c.initialize(
      retryService: MessageRetryService(),
      pathHistoryService: PathHistoryService(StorageService()),
    );
    c.sendFrameOverrideForTest = (_) {};
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  // [savedList] is what the connect-time startup load reads back for a radio
  // this app has used before: its own last confirmed channel list.
  Future<void> becomeRadio(
    Uint8List key,
    List<Channel> layout, {
    List<Channel>? savedList,
  }) async {
    c.setConnectedForTest();
    c.setSelfPublicKeyForTest(key);
    c.wireMessageStoreForTest();
    if (savedList != null) c.seedCachedChannelsForTest(savedList);
    await c.getChannels(force: true, maxChannels: layout.length);
    for (final ch in layout) {
      c.handleFrameForTest(_channelInfoFrame(ch));
      await _settle(2);
    }
    await _settle();
  }

  // The radio switch the owner does: drop radio A, connect radio B over
  // Bluetooth. The fake device cannot actually connect in a test; what matters
  // is everything the connect does before it reaches the radio.
  Future<void> switchOverBluetooth() async {
    await c.disconnect(manual: true);
    try {
      await c
          .connect(BluetoothDevice.fromId('00:11:22:33:44:55'))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<List<String>> storedTexts(Uint8List radio, Channel ch) async {
    final store = ChannelMessageStore()
      ..setPublicKeyHex = _hex(radio)
      ..channelPskResolver = ((_) => ch.pskHex);
    return (await store.loadChannelMessages(
      ch.index,
    )).map((m) => m.text).toList();
  }

  test("a Bluetooth connect drops the previous radio's channel and DM history "
      'from memory', () async {
    final alpha = _channel(0, 'Alpha', 10);
    await becomeRadio(_radioA, [alpha]);
    c.handleFrameForTest(_channelMsgFrame(channelIdx: 0, text: 'A: one'));
    await _settle();
    c.conversationsForTest['deadbeef00'] = [];
    c.loadedConversationKeysForTest.add('deadbeef00');
    expect(c.channelMessagesForTest[0], isNotEmpty);

    await switchOverBluetooth();

    expect(c.channelMessagesForTest, isEmpty);
    expect(c.conversationsForTest, isEmpty);
    expect(c.loadedConversationKeysForTest, isEmpty);
    expect(
      c.channels,
      isEmpty,
      reason: "radio A's channel list must not answer for radio B's slots",
    );
    expect(c.cachedChannels, isEmpty);
  });

  test("returning to radio B never saves radio A's messages into B's channel on "
      'the same slot', () async {
    final alpha = _channel(0, 'Alpha', 10);
    final gamma = _channel(0, 'Gamma', 70);

    await becomeRadio(_radioA, [alpha]);
    c.handleFrameForTest(_channelMsgFrame(channelIdx: 0, text: 'A: from A'));
    await _settle();

    // Radio B has been used before, so its saved list already says slot 0 is
    // Gamma. The post-sync check then sees no change on slot 0 and keeps
    // whatever is in memory there, which before the fix was radio A's history.
    await switchOverBluetooth();
    await becomeRadio(_radioB, [gamma], savedList: [gamma]);
    c.handleFrameForTest(_channelMsgFrame(channelIdx: 0, text: 'B: from B'));
    await _settle();

    expect(
      await storedTexts(_radioB, gamma),
      ['from B'],
      reason:
          "the bug: radio A's slot-0 message was saved into radio B's "
          'slot-0 channel',
    );
    expect(await storedTexts(_radioA, alpha), ['from A']);
    expect(
      (c.channelMessagesForTest[0] ?? const <ChannelMessage>[]).map(
        (m) => m.text,
      ),
      ['from B'],
    );
  });

  test('a confirmed sync reloads a slot whose history was loaded under another '
      'channel, even when the saved list already matches the radio', () async {
    final alpha = _channel(0, 'Alpha', 10);
    final gamma = _channel(0, 'Gamma', 70);
    Future<void> storeHistory(Channel ch, String text) async {
      final store = ChannelMessageStore()
        ..setPublicKeyHex = _hex(_radioB)
        ..channelPskResolver = ((_) => ch.pskHex);
      await store.saveChannelMessages(ch.index, [
        ChannelMessage(
          senderName: 'X',
          text: text,
          timestamp: DateTime.fromMillisecondsSinceEpoch(5000),
          isOutgoing: false,
          status: ChannelMessageStatus.sent,
          channelIndex: 0,
        ),
      ]);
    }

    await storeHistory(alpha, 'alpha history');
    await storeHistory(gamma, 'gamma history');

    c.setConnectedForTest();
    c.setSelfPublicKeyForTest(_radioB);
    c.wireMessageStoreForTest();
    // The window loads while slot 0 resolves to Alpha...
    c.seedCachedChannelsForTest([alpha]);
    await c.loadAllChannelMessages(maxChannels: 1);
    expect(c.channelMessagesForTest[0]!.map((m) => m.text), ['alpha history']);

    // ...then the saved list says Gamma, and the radio confirms Gamma. The
    // saved-list diff sees no change on slot 0.
    await becomeRadio(_radioB, [gamma], savedList: [gamma]);
    await _settle();

    expect(c.channelMessagesForTest[0]!.map((m) => m.text), ['gamma history']);
  });

  test(
    'a new message saves only itself, never the rest of the window',
    () async {
      // Defense in depth: whatever else is in memory for a slot, right or wrong,
      // a new arrival must not write it into the channel's stored history.
      final gamma = _channel(0, 'Gamma', 70);
      await becomeRadio(_radioB, [gamma]);
      c.channelMessagesForTest[0] = [
        ChannelMessage(
          senderName: 'Elsewhere',
          text: 'stray, never stored here',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          isOutgoing: false,
          status: ChannelMessageStatus.sent,
          channelIndex: 0,
        ),
      ];

      c.handleFrameForTest(_channelMsgFrame(channelIdx: 0, text: 'B: new'));
      await _settle();

      expect(await storedTexts(_radioB, gamma), ['new']);
    },
  );
}
