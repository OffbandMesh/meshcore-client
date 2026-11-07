// #1026 on top of #1063: what a confirmed channel write does to PSK-keyed
// history.
//
// History is keyed by the channel's PSK (#194). Giving a slot to a different
// channel is a reassignment: the old channel's history is kept, so it comes
// back if that channel is ever re-added (#1063). Deleting a channel is the one
// path that removes its history outright. Both happen only after the radio's
// OK (#1026). Exercised through the real store, not the in-memory map.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

List<int> channelInfo(int index, String name, Uint8List key) => [
  respCodeChannelInfo,
  index,
  ...name.codeUnits,
  ...List<int>.filled(32 - name.length, 0),
  ...key,
];

ChannelMessage msg(String text) => ChannelMessage(
  senderName: 's',
  text: text,
  timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
  isOutgoing: false,
  channelIndex: 0,
  messageId: text,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;

  final weather = Channel(index: 0, name: 'Weather', psk: psk(0x22));

  /// Reads the history stored under [weather]'s PSK, whatever slot it is in.
  late ChannelMessageStore weatherHistory;

  Future<void> settle() => Future<void>.delayed(Duration.zero);
  void ok() => connector.handleFrameForTest([respCodeOk]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (_) {};
    connector.setConnectedForTest();
    connector.setSelfPublicKeyForTest(
      Uint8List.fromList(List<int>.generate(32, (i) => i)),
    );
    connector.wireMessageStoreForTest();

    // The radio holds Weather in slot 0.
    await connector.getChannels(maxChannels: 1, force: true);
    connector.handleFrameForTest(channelInfo(0, weather.name, weather.psk));
    await settle();
    expect(connector.channels.single.pskHex, weather.pskHex);

    weatherHistory = ChannelMessageStore()
      ..setPublicKeyHex = connector.selfPublicKeyHex
      ..channelPskResolver = (_) => weather.pskHex;
    await weatherHistory.saveChannelMessages(0, [msg('kept')]);
    expect(await weatherHistory.loadChannelMessages(0), hasLength(1));
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  test(
    'a slot given to another channel keeps the old one\'s history',
    () async {
      final write = connector.setChannel(0, 'Other', psk(0x33), refresh: false);
      ok();

      expect(await write, ChannelWrite.ok);
      expect(await weatherHistory.loadChannelMessages(0), hasLength(1));
    },
  );

  test('a new key by edit keeps the old key\'s history too', () async {
    final edit = connector.editChannel(weather, 'Weather', psk(0x99));
    await settle();
    ok(); // the clear
    for (var i = 0; i < 50; i++) {
      await settle();
    }
    ok(); // the add

    expect(await edit, ChannelWrite.ok);
    expect(await weatherHistory.loadChannelMessages(0), hasLength(1));
  });

  test('a confirmed delete removes the channel\'s history', () async {
    final delete = connector.deleteChannel(0, refresh: false);
    ok();

    expect(await delete, ChannelWrite.ok);
    expect(await weatherHistory.loadChannelMessages(0), isEmpty);
  });

  test('a refused delete keeps it', () async {
    final delete = connector.deleteChannel(0, refresh: false);
    connector.handleFrameForTest([respCodeErr, errCodeNotFound]);

    expect(await delete, ChannelWrite.rejected);
    expect(await weatherHistory.loadChannelMessages(0), hasLength(1));
  });
}
