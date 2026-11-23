// #1163: a channel write the radio did not answer is checked against a re-read
// before the user is told it was not confirmed. A lost reply is not a lost
// write; the owner was sent to fix channels that were in fact fine.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

List<int> _channelInfo(int index, String name, Uint8List psk) => [
  respCodeChannelInfo,
  index,
  ...name.codeUnits,
  ...List<int>.filled(32 - name.length, 0),
  ...psk,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector c;

  // What the fake radio holds per slot. It answers every channel read and
  // never answers a channel write: the reply was lost.
  late Map<int, (String, Uint8List)> radio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    radio = {};
    c = MeshCoreConnector();
    c.setConnectedForTest();
    c.channelWriteReplyTimeout = const Duration(milliseconds: 20);
    c.sendFrameOverrideForTest = (frame) {
      if (frame.isEmpty || frame[0] != cmdGetChannel) return;
      final index = frame[1];
      final (name, psk) = radio[index] ?? ('', Uint8List(16));
      Future<void>.microtask(
        () => c.handleFrameForTest(_channelInfo(index, name, psk)),
      );
    };
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  group('an add with no reply', () {
    test('is reported done when the re-read shows the channel', () async {
      radio[3] = ('Weather', _psk(0x22)); // the write landed

      final result = await c.setChannel(3, 'Weather', _psk(0x22));

      expect(result, ChannelWrite.ok);
    });

    test('is still not confirmed when the re-read does not show it', () async {
      final result = await c.setChannel(3, 'Weather', _psk(0x22));

      expect(result, ChannelWrite.noReply);
    });
  });

  test('a disconnect during the re-read ends the wait at once', () async {
    // The radio goes quiet: no reply to the write, none to the re-read.
    c.sendFrameOverrideForTest = (_) {};
    final write = c.setChannel(3, 'Weather', _psk(0x22));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(c.isSyncingChannels, isTrue, reason: 'the re-read is running');

    await c.disconnect(manual: true);

    expect(
      await write.timeout(const Duration(seconds: 5)),
      ChannelWrite.noReply,
      reason: 'before the fix this waited out the 30 s guard',
    );
  });

  group('a delete with no reply', () {
    test('is reported done when the re-read shows the slot empty', () async {
      final result = await c.deleteChannel(3);

      expect(result, ChannelWrite.ok);
    });

    test('is still not confirmed when the channel is still there', () async {
      radio[3] = ('Weather', _psk(0x22));

      final result = await c.deleteChannel(3);

      expect(result, ChannelWrite.noReply);
    });
  });
}
