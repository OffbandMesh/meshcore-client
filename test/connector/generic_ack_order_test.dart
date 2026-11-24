// #1028: a removal the radio answered with OK in 580 ms timed out as "the
// radio didn't respond" (owner's prune test, 2026-11-24).
//
// Replies to OK/ERR commands are matched by order. sendFrame registered a
// command's place in that order only after the transport write returned. A
// Bluetooth write on Windows can return after the radio's OK has already been
// handled; that OK then matched nothing, and the late registration sat at the
// front of the queue and took the next command's reply. These tests play the
// radio answering inside the write.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  /// When set, the radio's answer to a channel message lands while the write
  /// is still in progress.
  int? answerInsideWrite;

  void reply(int? errCode) => connector.handleFrameForTest(
    errCode == null ? [respCodeOk] : [respCodeErr, errCode],
  );

  Future<void> settle([int turns = 25]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ChannelMessage pending(String id) => ChannelMessage(
    senderName: 'Me',
    text: 'hello',
    timestamp: DateTime.utc(2026, 11, 24),
    isOutgoing: true,
    channelIndex: 0,
    messageId: id,
  );

  Uint8List channelFrame() =>
      Uint8List.fromList([cmdSendChannelTxtMsg, 0, 0, 0, 0, 0, 0, 104, 105]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.setConnectedForTest();
    sent = [];
    answerInsideWrite = null;
    connector.sendFrameOverrideForTest = (frame) {
      sent.add(frame);
      if (frame[0] == cmdSendChannelTxtMsg && answerInsideWrite != null) {
        reply(answerInsideWrite == -1 ? null : answerInsideWrite);
      }
    };
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  test(
    'an OK that lands during the write still marks the message sent',
    () async {
      connector.channelMessagesForTest[0] = [pending('m1')];
      answerInsideWrite = -1; // OK

      await connector.sendFrame(
        channelFrame(),
        channelSendQueueId: 'm1',
        expectsGenericAck: true,
      );
      await settle();

      expect(
        connector.channelMessagesForTest[0]!.single.status,
        ChannelMessageStatus.sent,
      );
    },
  );

  test('the next command still gets its own answer', () async {
    connector.channelMessagesForTest[0] = [pending('m1')];
    answerInsideWrite = -1;
    await connector.sendFrame(
      channelFrame(),
      channelSendQueueId: 'm1',
      expectsGenericAck: true,
    );
    answerInsideWrite = null;

    final write = connector.setChannel(
      3,
      'Weather',
      _psk(0x22),
      refresh: false,
    );
    await settle(2);
    reply(errCodeBadState);

    expect(await write, ChannelWrite.occupied);
  });

  test('a write that fails leaves nothing waiting', () async {
    connector.sendFrameOverrideForTest = (_) => throw Exception('link lost');
    await expectLater(
      connector.sendFrame(channelFrame(), expectsGenericAck: true),
      throwsException,
    );

    connector.sendFrameOverrideForTest = sent.add;
    final write = connector.setChannel(
      3,
      'Weather',
      _psk(0x22),
      refresh: false,
    );
    await settle(2);
    reply(errCodeBadState);

    expect(await write, ChannelWrite.occupied);
  });
}
