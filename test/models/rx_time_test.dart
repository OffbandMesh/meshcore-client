import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/models/message.dart';

void main() {
  final rx = DateTime(2026, 7, 18, 22, 47, 3);
  final claimed = DateTime(2026, 5, 15, 17, 38, 12);

  group('Message.rxTime (#285)', () {
    Message build({DateTime? rxTime}) => Message(
      senderKey: Uint8List(32),
      text: 'hello',
      timestamp: claimed,
      isOutgoing: false,
      rxTime: rxTime,
    );

    test('defaults to null (never fabricated)', () {
      expect(build().rxTime, isNull);
    });

    test('copyWith sets rxTime', () {
      expect(build().copyWith(rxTime: rx).rxTime, rx);
    });

    test('copyWith of unrelated fields preserves rxTime', () {
      final msg = build(rxTime: rx).copyWith(status: MessageStatus.delivered);
      expect(msg.rxTime, rx);
      expect(msg.timestamp, claimed);
    });
  });

  group('ChannelMessage.rxTime (#285)', () {
    ChannelMessage build({DateTime? rxTime}) => ChannelMessage(
      senderName: 'kd8zsp_tdeck',
      text: 'hello',
      timestamp: claimed,
      isOutgoing: false,
      rxTime: rxTime,
    );

    test('defaults to null (never fabricated)', () {
      expect(build().rxTime, isNull);
    });

    test('copyWith sets rxTime', () {
      expect(build().copyWith(rxTime: rx).rxTime, rx);
    });

    test('copyWith(packetHash:) — the live ingest path — preserves rxTime', () {
      final msg = build(rxTime: rx).copyWith(packetHash: 'abc123');
      expect(msg.rxTime, rx);
      expect(msg.timestamp, claimed);
    });
  });
}
