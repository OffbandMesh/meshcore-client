// #1183: a channel repeat is the same packet heard again, so it carries the
// sender's exact send second. Two sends of the same text are two packets (the
// client gives each send its own second), and must stay two messages, each
// counting only the repeaters that heard it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

const int _slot = 0;
const String _self = 'Base';

final Uint8List _psk = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));

Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// SELF_INFO, so the connector knows its own name (the self-echo drop needs it).
Uint8List _selfInfo() =>
    (BytesBuilder()
          ..addByte(respCodeSelfInfo)
          ..addByte(advTypeChat)
          ..addByte(20) // tx power
          ..addByte(22) // max tx power
          ..add(List<int>.filled(pubKeySize, 0x5A))
          ..add(_u32(0)) // lat
          ..add(_u32(0)) // lon
          ..addByte(0) // multi acks
          ..addByte(0) // advert location policy
          ..addByte(0) // telemetry modes
          ..addByte(0) // manual add
          ..add(_u32(910525000))
          ..add(_u32(62500))
          ..addByte(7)
          ..addByte(5)
          ..add(utf8.encode(_self))
          ..addByte(0))
        .toBytes();

List<int> _channelInfo() => [
  respCodeChannelInfo,
  _slot,
  ...'Public'.codeUnits,
  ...List<int>.filled(32 - 'Public'.length, 0),
  ..._psk,
];

/// A GRP_TXT packet as the radio overhears it, wrapped in 0x88: the same
/// AES-128-ECB + 2-byte HMAC the firmware uses.
Uint8List _rxLogFrame(int ts, String sender, String text, {List<int>? path}) {
  final plain = BytesBuilder()
    ..add(_u32(ts))
    ..addByte(txtTypePlain)
    ..add(utf8.encode('$sender: $text'))
    ..addByte(0);
  final padded = Uint8List(((plain.length + 15) ~/ 16) * 16)
    ..setRange(0, plain.length, plain.toBytes());
  final aes = ECBBlockCipher(AESEngine())..init(true, KeyParameter(_psk));
  final cipher = Uint8List(padded.length);
  for (var i = 0; i < padded.length; i += 16) {
    aes.processBlock(padded, i, cipher, i);
  }
  final key32 = Uint8List(32)..setRange(0, 16, _psk);
  final mac = crypto.Hmac(crypto.sha256, key32).convert(cipher).bytes;
  final hops = path ?? const <int>[];
  return (BytesBuilder()
        ..addByte(pushCodeLogRxData)
        ..addByte(0) // snr
        ..addByte(0) // rssi
        ..addByte((0x05 << 2) | 0x01) // GRP_TXT, flood
        ..addByte(hops.length) // 1-byte hashes, one per hop
        ..add(hops)
        ..addByte(crypto.sha256.convert(_psk).bytes[0])
        ..add(mac.sublist(0, 2))
        ..add(cipher))
      .toBytes();
}

/// The same packet delivered through the radio's message queue (V3).
/// [deviceComposed] sets reserved1 bit 0: written on the radio's own screen.
Uint8List _queueFrame(
  int ts,
  String sender,
  String text, {
  bool deviceComposed = false,
}) =>
    (BytesBuilder()
          ..addByte(respCodeChannelMsgRecvV3)
          ..addByte(0) // snr
          ..addByte(deviceComposed ? 0x01 : 0x00) // reserved1
          ..addByte(0) // reserved2
          ..addByte(_slot)
          ..addByte(1) // one hop
          ..addByte(txtTypePlain)
          ..add(_u32(ts))
          ..add(utf8.encode('$sender: $text'))
          ..addByte(0))
        .toBytes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<Uint8List> sent;

  List<ChannelMessage> messages() =>
      connector.channelMessagesForTest[_slot] ?? const [];

  /// The seconds each channel send put on the wire, in send order.
  List<int> sentSeconds() => sent
      .where((f) => f.isNotEmpty && f[0] == cmdSendChannelTxtMsg)
      .map((f) => ByteData.sublistView(f, 3, 7).getUint32(0, Endian.little))
      .toList();

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> sendTwice(String text) async {
    final channel = connector.channels.firstWhere((c) => c.index == _slot);
    await Future.wait([
      connector.sendChannelMessage(channel, text),
      connector.sendChannelMessage(channel, text),
    ]);
    expect(sentSeconds(), hasLength(2));
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
    connector.handleFrameForTest(_selfInfo());
    await settle();
    expect(connector.selfName, _self);

    await connector.getChannels(maxChannels: 1, force: true);
    connector.handleFrameForTest(_channelInfo());
    await settle();
    expect(connector.canSendOnChannel(_slot), isTrue);
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  test(
    'two sends of the same text stay two messages, neither repeated',
    () async {
      await sendTwice('hello');

      expect(messages(), hasLength(2));
      for (final m in messages()) {
        expect(m.isOutgoing, isTrue);
        expect(m.repeatCount, 0);
        expect(m.status, ChannelMessageStatus.pending);
      }
    },
  );

  test('a repeat of the second send counts on the second send only', () async {
    await sendTwice('hello');
    final ts = sentSeconds();

    connector.handleFrameForTest(
      _rxLogFrame(ts[1], _self, 'hello', path: [0xAB]),
    );
    await settle();

    expect(messages(), hasLength(2));
    expect(messages()[0].repeatCount, 0);
    expect(messages()[1].repeatCount, 1);
  });

  test('two repeaters of the first send count on the first only', () async {
    await sendTwice('hello');
    final ts = sentSeconds();

    connector.handleFrameForTest(
      _rxLogFrame(ts[0], _self, 'hello', path: [0xAB]),
    );
    await settle();
    expect(messages()[0].repeatCount, 1);

    connector.handleFrameForTest(
      _rxLogFrame(ts[0], _self, 'hello', path: [0xCD]),
    );
    await settle();

    expect(messages(), hasLength(2));
    expect(messages()[0].repeatCount, 2);
    expect(messages()[1].repeatCount, 0);
  });

  test(
    'another sender\'s same text one second apart is two messages',
    () async {
      connector.handleFrameForTest(_queueFrame(1790000000, 'Bob', 'hi'));
      connector.handleFrameForTest(_queueFrame(1790000001, 'Bob', 'hi'));
      await settle();

      expect(messages(), hasLength(2));
      expect(messages().map((m) => m.repeatCount), everyElement(0));
    },
  );

  test(
    'a real repeat of another sender, by both paths, is one message',
    () async {
      connector.handleFrameForTest(_queueFrame(1790000000, 'Bob', 'hi'));
      await settle();
      connector.handleFrameForTest(
        _rxLogFrame(1790000000, 'Bob', 'hi', path: [0xCD]),
      );
      await settle();

      expect(messages(), hasLength(1));
      expect(messages().single.repeatCount, 1);
    },
  );

  test('a direct (no-path) copy of my own message is still dropped', () async {
    await sendTwice('hello');
    final ts = sentSeconds();

    connector.handleFrameForTest(_rxLogFrame(ts[0], _self, 'hello'));
    await settle();

    expect(messages(), hasLength(2));
    expect(messages().map((m) => m.repeatCount), everyElement(0));
  });

  test(
    'a copy whose second matches no message is new, never a repeat',
    () async {
      await sendTwice('hello');
      final ts = sentSeconds();

      connector.handleFrameForTest(
        _rxLogFrame(ts[1] + 5, _self, 'hello', path: [0xAB]),
      );
      await settle();

      expect(messages(), hasLength(3));
      expect(messages().map((m) => m.repeatCount), everyElement(0));
    },
  );

  // Messages written on the radio's own screen arrive as V3 frames with the
  // outgoing flag set, not through sendChannelMessage.
  group('composed on the radio itself', () {
    test('the same message delivered twice is one message', () async {
      final frame = _queueFrame(
        1790000000,
        _self,
        'from the badge',
        deviceComposed: true,
      );
      connector.handleFrameForTest(frame);
      connector.handleFrameForTest(frame);
      await settle();

      expect(messages(), hasLength(1));
      expect(messages().single.isOutgoing, isTrue);
    });

    test('two sends of the same text a second apart are two', () async {
      connector.handleFrameForTest(
        _queueFrame(1790000000, _self, 'again', deviceComposed: true),
      );
      connector.handleFrameForTest(
        _queueFrame(1790000001, _self, 'again', deviceComposed: true),
      );
      await settle();

      expect(messages(), hasLength(2));
      expect(messages().map((m) => m.repeatCount), everyElement(0));
    });
  });
}
