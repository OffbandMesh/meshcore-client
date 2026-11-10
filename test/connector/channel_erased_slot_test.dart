// #1060: a radio that has LOST its channel storage still answers for every
// slot. Erased flash reads back as 0xFF, so the reply is a well-formed
// CHANNEL_INFO frame carrying garbage, not silence and not an error.
//
// The field case: a reflash between two sessions left slot 0 ("Public")
// intact and slots 1+ entirely 0xFF. The client adopted those records as
// channels, rendered their names as replacement characters, and then
// persisted them over the user's own good cached list, turning one-sided loss
// on the radio into loss on both sides.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/storage/channel_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
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

/// Everything after the slot index reads back as erased flash.
Uint8List _erasedFrame(int index) {
  final frame = Uint8List(50);
  frame[0] = respCodeChannelInfo;
  frame[1] = index;
  for (var i = 2; i < 50; i++) {
    frame[i] = 0xFF;
  }
  return frame;
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

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector c;
  late List<List<int>> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    sent = [];
    c = MeshCoreConnector();
    c.sendFrameOverrideForTest = (data) => sent.add(data.toList());
    c.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  group('the erased record itself', () {
    test('an all-0xFF record is erased, and is NOT caught by isEmpty', () {
      final erased = Channel.fromFrame(_erasedFrame(1))!;

      expect(erased.isErased, isTrue);
      expect(erased.isUnusable, isTrue);
      // This is the exact gap that let the garbage through: isEmpty tests for
      // 0x00, and erased flash is 0xFF.
      expect(
        erased.isEmpty,
        isFalse,
        reason: 'if this ever passes, isEmpty alone would have been enough',
      );
    });

    test('the erased name is replacement characters, which is what showed', () {
      final erased = Channel.fromFrame(_erasedFrame(1))!;
      expect(erased.name, contains('�'));
    });

    test('a real channel is neither empty nor erased', () {
      final real = Channel.fromFrame(
        _channelInfoFrame(index: 0, name: 'Public', pskSeed: 10),
      )!;

      expect(real.isErased, isFalse);
      expect(real.isEmpty, isFalse);
      expect(real.isUnusable, isFalse);
      expect(real.name, 'Public');
    });

    test('a genuinely empty slot is still empty, not erased', () {
      final empty = Channel.fromFrame(
        Uint8List(50)..[0] = respCodeChannelInfo,
      )!;

      expect(empty.isEmpty, isTrue);
      expect(empty.isErased, isFalse);
      expect(empty.isUnusable, isTrue);
    });
  });

  group('sync against a radio that lost its channels', () {
    /// The field case: slot 0 survived, slots 1 and 2 came back erased.
    Future<void> syncWithErasedTail() async {
      await c.getChannels(force: true, maxChannels: 3);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Public', pskSeed: 10),
      );
      await _settle(2);
      c.handleFrameForTest(_erasedFrame(1));
      await _settle(2);
      c.handleFrameForTest(_erasedFrame(2));
      await _settle();
    }

    test('erased slots are not adopted as channels', () async {
      await syncWithErasedTail();

      expect(c.channels.map((ch) => ch.index), [0]);
      expect(c.channels.single.name, 'Public');
      expect(
        c.channels.any((ch) => ch.name.contains('�')),
        isFalse,
        reason: 'no channel may be named with replacement characters',
      );
    });

    test(
      'erased slots are reported, so the UI can say what happened',
      () async {
        await syncWithErasedTail();

        expect(c.erasedChannelSlots, {1, 2});
      },
    );

    test('the good cached list is NOT overwritten', () async {
      c.seedCachedChannelsForTest([
        _channel(0, 'Public', 10),
        _channel(1, 'wardriving', 40),
        _channel(2, 'test', 50),
      ]);

      await syncWithErasedTail();

      // The data-loss fix: the client keeps its own copy of the channels the
      // radio has lost, rather than saving erased records over them.
      expect(c.cachedChannels.map((ch) => ch.name), [
        'Public',
        'wardriving',
        'test',
      ]);
      expect(c.canRestoreChannelsToRadio, isTrue);
    });

    test('a clean sync still replaces the cache', () async {
      c.seedCachedChannelsForTest([_channel(0, 'stale', 99)]);

      await c.getChannels(force: true, maxChannels: 2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Public', pskSeed: 10),
      );
      await _settle(2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 1, name: 'wardriving', pskSeed: 40),
      );
      await _settle();

      expect(
        c.cachedChannels.map((ch) => ch.name),
        ['Public', 'wardriving'],
        reason: 'the guard must not block a healthy sync',
      );
      expect(c.erasedChannelSlots, isEmpty);
      expect(c.canRestoreChannelsToRadio, isFalse);
    });
  });

  // #1117: the restore places by identity and reports what the radio
  // confirmed. Current firmware refuses an occupied slot (#1865), reads an
  // erased record as occupied, refuses any channel but Public in slot 0, and
  // refuses Public anywhere else (#1896).
  group('restoring the list to the radio', () {
    final realPublic = Channel(
      index: 0,
      name: 'Public',
      psk: Channel.parsePskHex(Channel.publicChannelPsk),
    );

    /// A radio that answers every channel write, OK unless [refuseSlot].
    void answerWrites({int? refuseSlot}) {
      c.sendFrameOverrideForTest = (data) {
        sent.add(data.toList());
        if (data.isNotEmpty && data[0] == cmdSetChannel) {
          final refused = data[1] == refuseSlot && data[2] != 0;
          c.handleFrameForTest(
            refused ? [respCodeErr, errCodeBadState] : [respCodeOk],
          );
        }
      };
    }

    List<List<int>> setFrames() =>
        sent.where((f) => f[0] == cmdSetChannel).toList();

    test('each missing channel goes back, its key with it', () async {
      c.seedCachedChannelsForTest([realPublic, _channel(1, 'wardriving', 40)]);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 2);
      expect(result.notRestored, isEmpty);
      final frames = setFrames();
      expect(frames.map((f) => f[1]), [0, 1], reason: 'Public in slot 0');
      // The PSK travels with it, so the restored channel keeps the identity
      // its history and settings are keyed by.
      expect(frames[1].sublist(34, 50), _channel(1, 'wardriving', 40).psk);
    });

    test('no channel but Public is restored into slot 0', () async {
      // Cached at slot 0 under older firmware, where any channel could sit
      // there. Current firmware refuses it there, so it moves.
      c.seedCachedChannelsForTest([_channel(0, 'old slot 0', 10)]);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 1);
      expect(setFrames().single[1], isNot(0));
    });

    test('an erased slot is cleared before it is written', () async {
      // The field case: slot 0 survived, slots 1 and 2 came back erased.
      await c.getChannels(force: true, maxChannels: 3);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'kept', pskSeed: 10),
      );
      await _settle(2);
      c.handleFrameForTest(_erasedFrame(1));
      await _settle(2);
      c.handleFrameForTest(_erasedFrame(2));
      await _settle();
      c.seedCachedChannelsForTest([_channel(1, 'wardriving', 40)]);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 1);
      final frames = setFrames();
      expect(frames.map((f) => f[1]), [1, 1]);
      expect(frames[0][2], 0, reason: 'the clear: an empty name');
      expect(frames[1].sublist(34, 50), _channel(1, 'wardriving', 40).psk);
    });

    test('a channel the radio still has is not written again', () async {
      await c.getChannels(force: true, maxChannels: 2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 1, name: 'wardriving', pskSeed: 40),
      );
      await _settle();
      c.seedCachedChannelsForTest([
        _channel(1, 'wardriving', 40),
        _channel(2, 'test', 70),
      ]);
      expect(c.channelsMissingFromRadio.map((ch) => ch.name), ['test']);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.total, 1);
      expect(setFrames().single.sublist(34, 50), _channel(2, 'test', 70).psk);
    });

    test('a live channel is never overwritten', () async {
      // Slot 1 now holds a different channel than the cache remembers there.
      await c.getChannels(force: true, maxChannels: 3);
      c.handleFrameForTest(
        _channelInfoFrame(index: 1, name: 'newer', pskSeed: 90),
      );
      await _settle();
      c.seedCachedChannelsForTest([_channel(1, 'wardriving', 40)]);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 1);
      expect(setFrames().single[1], 2, reason: 'moved, not over slot 1');
    });

    test('a refusal is reported by name, not counted as restored', () async {
      c.seedCachedChannelsForTest([
        _channel(1, 'wardriving', 40),
        _channel(2, 'test', 70),
      ]);
      answerWrites(refuseSlot: 2);

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 1);
      expect(result.total, 2);
      expect(result.notRestored.map((ch) => ch.name), ['test']);
    });

    test('an erased cached entry is never written back', () async {
      c.seedCachedChannelsForTest([
        _channel(1, 'wardriving', 40),
        Channel.fromFrame(_erasedFrame(2))!,
      ]);
      answerWrites();
      sent.clear();

      final result = await c.restoreChannelsToRadio();

      expect(result!.confirmed, 1);
      expect(setFrames().length, 1);
    });

    test(
      'restoring with nothing cached is refused, not a silent no-op',
      () async {
        c.seedCachedChannelsForTest([]);

        expect(await c.restoreChannelsToRadio(), isNull);
        expect(sent.where((f) => f[0] == cmdSetChannel), isEmpty);
      },
    );

    // Adversarial review finding (#1060): on BLE sendFrame returns when the
    // frame reaches the OS, not when the radio has taken it, so an unpaced
    // loop can overrun the radio. Each write now waits for the radio's own
    // answer before the next goes out, which paces it by the radio itself.
    test('the next write waits for the radio to answer the last', () async {
      c.seedCachedChannelsForTest([
        _channel(1, 'wardriving', 40),
        _channel(2, 'test', 70),
      ]);
      sent.clear();

      final restore = c.restoreChannelsToRadio();
      await _settle();
      expect(setFrames().length, 1, reason: 'nothing answered yet');

      c.handleFrameForTest([respCodeOk]);
      await _settle();
      expect(setFrames().length, 2);

      c.handleFrameForTest([respCodeOk]);
      expect((await restore)!.confirmed, 2);
    });
  });

  // Adversarial review finding: the guards added here stop an erased record
  // being adopted from the WIRE, but a build from before they existed could
  // already have persisted one. Storage is therefore an untrusted source too,
  // and _cachedChannels is a fallback identity source for _findChannelByIndex
  // as well as being re-saved by the unread paths, so one that slips in comes
  // back as the channel for live traffic and outlives every radio.
  group('erased records already sitting in storage', () {
    const radioKey = 'aabbccddee';

    test('are dropped on load, not adopted from the cache', () async {
      final store = ChannelStore()..setPublicKeyHex = radioKey;
      await store.saveChannels([
        _channel(0, 'Public', 10),
        Channel.fromFrame(_erasedFrame(1))!,
        _channel(2, 'wardriving', 40),
      ]);
      // The store itself is faithful: it persisted exactly what it was given,
      // which is how the bad record got there in the first place.
      expect((await store.loadChannels()).length, 3);

      c.setChannelStoreKeyForTest(radioKey);
      await c.loadCachedChannels();

      expect(c.cachedChannels.map((ch) => ch.name), ['Public', 'wardriving']);
      expect(c.cachedChannels.any((ch) => ch.isUnusable), isFalse);
    });

    test('a clean stored list is loaded untouched', () async {
      final store = ChannelStore()..setPublicKeyHex = radioKey;
      await store.saveChannels([
        _channel(0, 'Public', 10),
        _channel(1, 'wardriving', 40),
      ]);

      c.setChannelStoreKeyForTest(radioKey);
      await c.loadCachedChannels();

      expect(c.cachedChannels.length, 2);
      expect(c.cachedChannels.map((ch) => ch.name), ['Public', 'wardriving']);
    });

    test('an all-erased stored list leaves nothing to restore', () async {
      final store = ChannelStore()..setPublicKeyHex = radioKey;
      await store.saveChannels([
        Channel.fromFrame(_erasedFrame(0))!,
        Channel.fromFrame(_erasedFrame(1))!,
      ]);

      c.setChannelStoreKeyForTest(radioKey);
      await c.loadCachedChannels();

      expect(c.cachedChannels, isEmpty);
      // Nothing usable cached means the restore is refused rather than
      // writing erased records back onto the radio.
      expect(await c.restoreChannelsToRadio(), isNull);
      expect(sent.where((f) => f[0] == cmdSetChannel), isEmpty);
    });
  });
}
