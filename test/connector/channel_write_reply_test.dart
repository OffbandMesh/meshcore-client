// #1026 (epic #1021): a channel write waits for the radio's OK or ERR, and a
// slot's message history is cleared only once the radio has said OK.
//
// Firmware with OffbandMesh/meshcore-firmware#1864 refuses a different channel
// over an occupied slot with ERR_CODE_BAD_STATE and keeps that channel intact.
// Clearing its history on the strength of having sent the frame would lose it.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/channel_slot_decision.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  List<Uint8List> setFrames() =>
      sent.where((f) => f.isNotEmpty && f[0] == cmdSetChannel).toList();

  void ok() => connector.handleFrameForTest([respCodeOk]);
  void err(int code) => connector.handleFrameForTest([respCodeErr, code]);

  /// The second write of a clear-then-add goes out only after the first has
  /// been answered and its history cleared, which takes real async time.
  Future<void> untilSetFrames(int count) async {
    for (var i = 0; i < 2000 && setFrames().length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(setFrames(), hasLength(count));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.setConnectedForTest();
    sent = [];
    connector.sendFrameOverrideForTest = sent.add;
    connector.channelMessagesForTest[3] = [];
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  group('setChannel', () {
    test('OK clears the slot\'s old history and reports ok', () async {
      final write = connector.setChannel(
        3,
        'Weather',
        psk(0x22),
        refresh: false,
      );
      ok();

      expect(await write, ChannelWrite.ok);
      expect(connector.channelMessagesForTest.containsKey(3), isFalse);
    });

    test('BAD_STATE is occupied, and the history stays', () async {
      final write = connector.setChannel(
        3,
        'Weather',
        psk(0x22),
        refresh: false,
      );
      err(errCodeBadState);

      expect(await write, ChannelWrite.occupied);
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });

    test('any other ERR is rejected, and the history stays', () async {
      final write = connector.setChannel(
        3,
        'Weather',
        psk(0x22),
        refresh: false,
      );
      err(errCodeNotFound);

      expect(await write, ChannelWrite.rejected);
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });

    test('no reply is noReply, and the history stays', () async {
      connector.channelWriteReplyTimeout = const Duration(milliseconds: 20);
      final write = connector.setChannel(
        3,
        'Weather',
        psk(0x22),
        refresh: false,
      );

      expect(await write, ChannelWrite.noReply);
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });

    test('a timed-out write cannot take the next write\'s reply', () async {
      connector.channelWriteReplyTimeout = const Duration(milliseconds: 20);
      expect(
        await connector.setChannel(3, 'A', psk(0x22), refresh: false),
        ChannelWrite.noReply,
      );

      connector.channelWriteReplyTimeout = const Duration(seconds: 5);
      final second = connector.setChannel(4, 'B', psk(0x33), refresh: false);
      err(errCodeBadState);

      expect(await second, ChannelWrite.occupied);
    });

    test('the table is busy until the radio answers', () async {
      final write = connector.setChannel(
        3,
        'Weather',
        psk(0x22),
        refresh: false,
      );
      expect(connector.isChannelTableBusy, isTrue);

      ok();
      await write;
      expect(connector.isChannelTableBusy, isFalse);
    });

    test('disconnected sends nothing and reports noReply', () async {
      final fresh = MeshCoreConnector();
      fresh.sendFrameOverrideForTest = sent.add;

      expect(
        await fresh.setChannel(3, 'Weather', psk(0x22)),
        ChannelWrite.noReply,
      );
      expect(sent, isEmpty);
    });
  });

  group('deleteChannel', () {
    test('OK clears the history', () async {
      final delete = connector.deleteChannel(3, refresh: false);
      ok();

      expect(await delete, ChannelWrite.ok);
      expect(connector.channelMessagesForTest.containsKey(3), isFalse);
    });

    test('a refusal keeps the history', () async {
      final delete = connector.deleteChannel(3, refresh: false);
      err(errCodeNotFound);

      expect(await delete, ChannelWrite.rejected);
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });
  });

  group('editChannel', () {
    final current = Channel(index: 3, name: 'Weather', psk: psk(0x22));

    test('a rename is one write and keeps the history', () async {
      final edit = connector.editChannel(current, 'Wx', psk(0x22));
      ok();

      expect(await edit, ChannelWrite.ok);
      expect(setFrames(), hasLength(1));
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });

    test('a new key is clear-then-add, so #1864 firmware accepts it', () async {
      final edit = connector.editChannel(current, 'Weather', psk(0x99));
      await untilSetFrames(1);
      // The clear: an empty name.
      expect(setFrames()[0][2], 0);
      ok();

      await untilSetFrames(2);
      expect(setFrames()[1].sublist(2 + 32, 2 + 32 + 16), psk(0x99));
      ok();

      expect(await edit, ChannelWrite.ok);
      expect(connector.channelMessagesForTest.containsKey(3), isFalse);
    });

    test('a refused clear writes nothing more and keeps the history', () async {
      final edit = connector.editChannel(current, 'Weather', psk(0x99));
      await untilSetFrames(1);
      err(errCodeNotFound);

      expect(await edit, ChannelWrite.rejected);
      expect(setFrames(), hasLength(1));
      expect(connector.channelMessagesForTest.containsKey(3), isTrue);
    });

    test(
      'a clear that lands and an add that fails says the slot is empty',
      () async {
        final edit = connector.editChannel(current, 'Weather', psk(0x99));
        await untilSetFrames(1);
        ok(); // the clear lands

        await untilSetFrames(2);
        err(errCodeNotFound); // the add does not

        expect(await edit, ChannelWrite.clearedNotAdded);
      },
    );
  });

  // Gemini review of #1021: a sync started while a write waits for its reply
  // shares the reply queue with it, so the sync's empty-slot ERR could be
  // taken as the write's answer. The sync waits for the writes instead.
  group('a sync requested during a write', () {
    List<Uint8List> getFrames() =>
        sent.where((f) => f.isNotEmpty && f[0] == cmdGetChannel).toList();

    test('is deferred until the reply, then runs', () async {
      final write = connector.setChannel(3, 'A', psk(0x22), refresh: false);
      await connector.getChannels(force: true);
      expect(connector.isSyncingChannels, isFalse);
      expect(getFrames(), isEmpty);

      ok();
      expect(await write, ChannelWrite.ok);
      await Future<void>.delayed(Duration.zero);
      expect(connector.isSyncingChannels, isTrue);
      expect(getFrames(), isNotEmpty);
    });

    test('does not start between two writes of a batch', () async {
      final batch = connector.batchChannelWrites(() async {
        final first = connector.setChannel(3, 'A', psk(0x22), refresh: false);
        await connector.getChannels(force: true);
        ok();
        await first;
        await Future<void>.delayed(Duration.zero);
        // Between the two writes: the deferred sync must not have started.
        expect(connector.isSyncingChannels, isFalse);
        final second = connector.setChannel(4, 'B', psk(0x33), refresh: false);
        ok();
        return second;
      });

      expect(await batch, ChannelWrite.ok);
      expect(getFrames(), isNotEmpty, reason: 'runs once the batch ends');
    });
  });

  // #1024: after a FAILED sync the cached list is restored but
  // hasLoadedChannels stays false. Gating adds on hasLoadedChannels would lock
  // the user out of adding channels on a flaky link, so the table has to read
  // as usable here, driven through the real sync rather than asserted.
  group('after a failed sync', () {
    List<int> channelInfo(int index, String name, int fill) => [
      respCodeChannelInfo,
      index,
      ...name.codeUnits,
      ...List<int>.filled(32 - name.length, 0),
      ...psk(fill),
    ];

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test(
      'the restored list is not busy, and an add gets a free slot',
      () async {
        await connector.getChannels(maxChannels: 2, force: true);
        connector.handleFrameForTest(channelInfo(0, 'Public', 0x11));
        await settle();
        connector.handleFrameForTest(channelInfo(1, 'Weather', 0x22));
        await settle();
        expect(connector.hasLoadedChannels, isTrue);

        connector.sendFrameOverrideForTest = (_) =>
            throw Exception('link lost');
        await connector.getChannels(maxChannels: 2, force: true);
        await settle();

        expect(connector.hasLoadedChannels, isFalse);
        expect(connector.channels.map((c) => c.index), unorderedEquals([0, 1]));
        expect(connector.isChannelTableBusy, isFalse);
        final decision = decideChannelSlot(
          channels: connector.channels,
          maxChannels: 3,
          isSyncing: connector.isChannelTableBusy,
        );
        expect(decision.slot, 2);
      },
    );
  });
}
