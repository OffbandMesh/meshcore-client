// #1062 (Epic A of #1061, fixing #1060): the channel sync is fail-closed and
// atomic, live filing waits behind an ingress barrier, and per-slot state
// never follows a slot across an identity change.
//
// The #1060 field case: a wipe + config re-import rearranged the device's
// channel slots; the old sync backfilled unanswered slots from the previous
// list, so notifications fired for the wrong channel and messages rendered
// inside the wrong conversation.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _channelInfoFrame({
  required int index,
  required String name,
  required int pskSeed,
}) {
  final frame = Uint8List(50);
  frame[0] = respCodeChannelInfo;
  frame[1] = index;
  final nameBytes = name.codeUnits;
  for (var i = 0; i < nameBytes.length && i < 31; i++) {
    frame[2 + i] = nameBytes[i];
  }
  for (var i = 0; i < 16; i++) {
    frame[34 + i] = (pskSeed + i) & 0xFF;
  }
  return frame;
}

Uint8List _v3ChannelMsgFrame({required int channelIdx, String text = 'A: hi'}) {
  return Uint8List.fromList([
    respCodeChannelMsgRecvV3,
    0, 0, 0,
    channelIdx,
    1, // path_len: 1 hop, width 1
    txtTypePlain,
    0x40, 0xE2, 0x01, 0x00,
    ...text.codeUnits,
  ]);
}

Channel _channel(int index, String name, int pskSeed) {
  final psk = Uint8List.fromList(
    List<int>.generate(16, (i) => (pskSeed + i) & 0xFF),
  );
  return Channel(index: index, name: name, psk: psk);
}

MeshCoreConnector _connector() {
  final c = MeshCoreConnector();
  c.sendFrameOverrideForTest = (_) {};
  c.setConnectedForTest();
  c.setSelfPublicKeyForTest(
    Uint8List.fromList(List<int>.generate(32, (i) => i)),
  );
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test(
    'an unanswered slot stays UNKNOWN, never backfilled from cache (#1060)',
    () async {
      final c = _connector();
      c.seedCachedChannelsForTest([_channel(1, 'StaleOccupant', 70)]);

      await c.getChannels(maxChannels: 2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Fresh0', pskSeed: 10),
      );
      // Slot 1 never answers: exhaust the retries.
      for (var i = 0; i <= 3; i++) {
        c.handleChannelSyncTimeoutForTest(1);
        await Future<void>.delayed(Duration.zero);
      }

      expect(c.unconfirmedChannelSlots, {1});
      expect(c.channels.map((ch) => ch.name), ['Fresh0']);
      expect(
        c.channels.any((ch) => ch.name == 'StaleOccupant'),
        isFalse,
        reason: 'the stale cache occupant must not be restored into the slot',
      );
      expect(
        c.findChannelByIndexForTest(1),
        isNull,
        reason: 'lookups for an unconfirmed slot fail closed',
      );
    },
  );

  test(
    'messages arriving mid-sync are held, then filed after the sync',
    () async {
      final c = _connector();

      await c.getChannels(maxChannels: 2);
      // Barrier is up: a pushed message must not file yet.
      c.handleFrameForTest(_v3ChannelMsgFrame(channelIdx: 0));
      expect(c.channelMessagesForTest[0], isNull);

      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Alpha', pskSeed: 10),
      );
      await Future<void>.delayed(Duration.zero);
      c.handleFrameForTest(
        _channelInfoFrame(index: 1, name: 'Beta', pskSeed: 30),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.unconfirmedChannelSlots, isEmpty);
      expect(
        c.channelMessagesForTest[0],
        isNotNull,
        reason: 'the held frame files once the list is confirmed',
      );
      expect(c.channelMessagesForTest[0]!.single.text, 'hi');
    },
  );

  test(
    'unread count does not follow a slot across an identity change',
    () async {
      final c = _connector();
      final stale = _channel(0, 'OldChannel', 70)..unreadCount = 5;
      c.seedCachedChannelsForTest([stale]);

      await c.getChannels(maxChannels: 1);
      // Same slot, different PSK: a different channel lives here now.
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'NewChannel', pskSeed: 10),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.channels.single.name, 'NewChannel');
      expect(
        c.channels.single.unreadCount,
        0,
        reason: 'another identity\'s unread count must not ride the slot',
      );
      expect(c.slotIdentityChanges, isNotEmpty);
    },
  );

  test(
    'unread count IS preserved when the slot keeps the same channel',
    () async {
      final c = _connector();
      final same = _channel(0, 'Keep', 10)..unreadCount = 7;
      c.seedCachedChannelsForTest([same]);

      await c.getChannels(maxChannels: 1);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Keep', pskSeed: 10),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.channels.single.unreadCount, 7);
      expect(c.slotIdentityChanges, isEmpty);
    },
  );

  test(
    'in-memory messages do not follow a slot across an identity change (#1063)',
    () async {
      final c = _connector();
      c.seedCachedChannelsForTest([_channel(0, 'OldChannel', 70)]);
      c.channelMessagesForTest[0] = [
        ChannelMessage(
          senderName: 'x',
          text: 'old occupant message',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          isOutgoing: false,
          channelIndex: 0,
          messageId: 'old1',
        ),
      ];

      await c.getChannels(maxChannels: 1);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'NewChannel', pskSeed: 10),
      );
      // Settle the sync completion and the unawaited history reload.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        c.channelMessagesForTest[0] ?? const <ChannelMessage>[],
        isEmpty,
        reason:
            "the old occupant's conversation must not render under the new "
            'channel; the slot reloads from the NEW identity\'s (empty) store',
      );
    },
  );

  test(
    'in-memory messages stay when the slot keeps the same channel',
    () async {
      final c = _connector();
      c.seedCachedChannelsForTest([_channel(0, 'Keep', 10)]);
      c.channelMessagesForTest[0] = [
        ChannelMessage(
          senderName: 'x',
          text: 'kept',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          isOutgoing: false,
          channelIndex: 0,
          messageId: 'k1',
        ),
      ];

      await c.getChannels(maxChannels: 1);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Keep', pskSeed: 10),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.channelMessagesForTest[0]!.single.text, 'kept');
    },
  );

  test(
    'a sync with unconfirmed slots does not overwrite the offline cache',
    () async {
      final c = _connector();
      c.seedCachedChannelsForTest([
        _channel(0, 'GoodCache0', 10),
        _channel(1, 'GoodCache1', 30),
      ]);

      await c.getChannels(maxChannels: 2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Fresh0', pskSeed: 10),
      );
      for (var i = 0; i <= 3; i++) {
        c.handleChannelSyncTimeoutForTest(1);
        await Future<void>.delayed(Duration.zero);
      }

      expect(c.unconfirmedChannelSlots, {1});
      // The confirmed slot is live; the unconfirmed one is a hole, and the last
      // fully-confirmed cache survives for the next attempt (slot 0 lookup still
      // resolves, slot 1 fails closed).
      expect(c.findChannelByIndexForTest(0)?.name, 'Fresh0');
      expect(c.findChannelByIndexForTest(1), isNull);
    },
  );
}
