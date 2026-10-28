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
  });
}
