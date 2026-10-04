import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_adapters.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';

Uint8List _le32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

int _u32(List<int> b, int at) => ByteData.sublistView(
  Uint8List.fromList(b),
  at,
  at + 4,
).getUint32(0, Endian.little);

/// The client's own CMD_SEND_TXT_MSG layout (meshcore_protocol.dart).
Uint8List _dm(
  FakeContact to,
  String text, {
  int type = fwTxtTypePlain,
  int attempt = 0,
  int ts = 1790000100,
}) => Uint8List.fromList([
  fwCmdSendTxtMsg,
  type,
  attempt,
  ..._le32(ts),
  ...to.publicKey.sublist(0, 6),
  ...utf8.encode(text),
  0,
]);

Uint8List _chan(int index, String text, {int ts = 1790000100}) =>
    Uint8List.fromList([
      fwCmdSendChannelTxtMsg,
      fwTxtTypePlain,
      index,
      ..._le32(ts),
      ...utf8.encode(text),
      0,
    ]);

void main() {
  final alpha = FakeContact.keyed(0x11, 'Alpha');
  final flooded = FakeContact.keyed(0x22, 'Bravo');
  final routed = FakeContact(
    publicKey: Uint8List.fromList(List<int>.filled(32, 0x33)),
    name: 'Routed',
    outPathLength: 1,
    outPath: Uint8List.fromList([0x9A]),
  );

  FakeRadio radio({FakeRadioProfile? profile}) => FakeRadio(
    profile: profile,
    seed: FakeRadioSeed(
      contacts: [alpha, flooded, routed],
      channels: [FakeChannel(index: 0, name: 'Public')],
    ),
  );

  group('direct send (#772)', () {
    test('SENT carries flood flag, expected ACK and timeout', () {
      final r = radio();
      final sent = r.handle(_dm(flooded, 'hello')).single;
      expect(sent[0], fwRespSent);
      expect(sent[1], 1); // no known path: flood
      expect(sent.length, 10);
      expect(_u32(sent, 6), 3000);
      expect(r.handle(_dm(routed, 'hi')).single[1], 0); // direct
      expect(r.sentDirect.map((s) => s.text), ['hello', 'hi']);
    });

    test("the expected ACK is the client's own prediction", () {
      final r = radio();
      final sent = r.handle(_dm(alpha, 'hello', attempt: 2)).single;
      expect(
        _u32(sent, 2),
        MessageRetryService.computeExpectedAckHash(
          1790000100,
          2,
          'hello',
          r.seed.publicKey,
        ),
      );
    });

    test('the ACK arrives only when the fake clock reaches it', () {
      final r = radio()..ackDelay = const Duration(seconds: 2);
      final pushes = <Uint8List>[];
      r.pushes.listen(pushes.add);
      final ack = _u32(r.handle(_dm(alpha, 'hello')).single, 2);
      r.clock.advance(const Duration(seconds: 1));
      expect(pushes, isEmpty);
      r.clock.advance(const Duration(seconds: 1));
      expect(pushes.single[0], fwPushSendConfirmed);
      expect(_u32(pushes.single, 1), ack);
      expect(_u32(pushes.single, 5), 2000); // trip time
    });

    test('a CLI command expects no ACK, and none arrives', () {
      final r = radio();
      final pushes = <Uint8List>[];
      r.pushes.listen(pushes.add);
      final sent = r.handle(_dm(alpha, 'ver', type: fwTxtTypeCliData)).single;
      expect(_u32(sent, 2), 0);
      r.clock.advance(const Duration(minutes: 1));
      expect(pushes, isEmpty);
    });

    test('unknown recipient is NOT_FOUND; other text types UNSUPPORTED', () {
      final r = radio();
      final stranger = FakeContact.keyed(0x77, 'Stranger');
      expect(r.handle(_dm(stranger, 'x')).single, [fwRespErr, fwErrNotFound]);
      expect(r.handle(_dm(alpha, 'x', type: fwTxtTypeSignedPlain)).single, [
        fwRespErr,
        fwErrUnsupportedCmd,
      ]);
      expect(r.sentDirect, isEmpty);
    });
  });

  group('channel send', () {
    test('OK for a known channel, NOT_FOUND otherwise', () {
      final r = radio();
      expect(r.handle(_chan(0, 'hi all')).single, [fwRespOk]);
      expect(r.handle(_chan(3, 'nobody')).single, [fwRespErr, fwErrNotFound]);
      expect(r.sentChannel.single.text, 'hi all');
    });

    test('Offband answers 0xC6 with the recorded hash, echoing the key', () {
      final r = radio();
      r.handle(_chan(0, 'hi all', ts: 1790000200));
      final reply = r
          .handle(
            Uint8List.fromList([
              fwOffbandPktHash,
              fwPktHashGet,
              ..._le32(1790000200),
              0,
            ]),
          )
          .single;
      expect(reply.sublist(0, 2), [fwOffbandPktHash, fwPktHashGet]);
      expect(_u32(reply, 2), 1790000200);
      expect(reply[6], 0);
      expect(reply.sublist(7), r.sentPktHash(1790000200, 0));
      expect(reply.length, 15);
    });

    test('the hash ring keeps the last 8 sends', () {
      final r = radio();
      for (var i = 0; i < 9; i++) {
        r.handle(_chan(0, 'm$i', ts: 1790000000 + i));
      }
      expect(r.sentPktHash(1790000000, 0), isNull);
      expect(r.sentPktHash(1790000008, 0), isNotNull);
    });
  });

  group('incoming messages', () {
    test('a DM queues a V3 frame and tickles the app', () {
      final r = radio();
      final pushes = <Uint8List>[];
      r.pushes.listen(pushes.add);
      r.receiveDirect(alpha, 'yo', timestamp: 1790000300, rssiDbm: -130);
      expect(pushes.single, [fwPushMsgWaiting]);
      final f = r.handle(Uint8List.fromList([fwCmdSyncNextMessage])).single;
      expect(f[0], fwRespContactMsgRecvV3);
      expect(f[2], 0); // received, not device-composed
      expect(f[3], (-128) & 0xFF); // RSSI clamped to int8
      expect(f.sublist(4, 10), alpha.publicKey.sublist(0, 6));
      expect(f[10], 0xFF);
      expect(f[11], fwTxtTypePlain);
      expect(_u32(f, 12), 1790000300);
      expect(utf8.decode(f.sublist(16)), 'yo');
    });

    test('an app below protocol v3 gets the legacy frame', () {
      final r = radio();
      r.handle(Uint8List.fromList([fwCmdDeviceQuery, 2]));
      r.receiveDirect(alpha, 'old');
      final f = r.handle(Uint8List.fromList([fwCmdSyncNextMessage])).single;
      expect(f[0], fwRespContactMsgRecv);
      expect(f.sublist(1, 7), alpha.publicKey.sublist(0, 6));
    });

    test('a channel message carries the slot and "Sender: text"', () {
      final r = radio();
      r.receiveChannel(0, 'Bravo: morning', timestamp: 1790000400);
      final f = r.handle(Uint8List.fromList([fwCmdSyncNextMessage])).single;
      expect(f[0], fwRespChannelMsgRecvV3);
      expect(f[4], 0);
      expect(_u32(f, 7), 1790000400);
      expect(utf8.decode(f.sublist(11)), 'Bravo: morning');
    });

    test('Offband drops a DM from a blocked sender; stock delivers it', () {
      final offband = radio()..blockedKeys.add(alpha.publicKey);
      offband.receiveDirect(alpha, 'blocked');
      expect(offband.offlineQueue, isEmpty);

      final stock = radio(profile: FakeRadioProfile.stock())
        ..blockedKeys.add(alpha.publicKey);
      stock.receiveDirect(alpha, 'delivered');
      expect(stock.offlineQueue, hasLength(1));
    });
  });

  group('through the real connector', () {
    late OffbandDatabase db;
    late MeshCoreConnector connector;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      connector = MeshCoreConnector();
    });

    tearDown(() async {
      await connector.disconnect();
      BlobStore.clearTestOverride();
      await db.close();
    });

    test(
      'an incoming DM lands in the conversation',
      () async {
        final r = radio();
        final link = await FakeRadioInProcess.connect(connector, r);
        addTearDown(link.close);
        final sw = Stopwatch()..start();
        while (!connector.contacts.any((c) => c.name == 'Alpha')) {
          if (sw.elapsed > const Duration(seconds: 10)) fail('no contacts');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        r.receiveDirect(alpha, 'hello from the mesh');
        final contact = connector.contacts.firstWhere((c) => c.name == 'Alpha');
        while (!connector
            .getMessages(contact)
            .any((m) => m.text == 'hello from the mesh' && !m.isOutgoing)) {
          if (sw.elapsed > const Duration(seconds: 10)) fail('no message');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
