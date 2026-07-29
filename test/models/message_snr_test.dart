import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/message.dart';

void main() {
  Uint8List key(int b) => Uint8List.fromList(List<int>.filled(32, b));

  group('Message SNR/RSSI/route fields (#438)', () {
    test('defaults are null (legacy/outgoing records)', () {
      final m = Message(
        senderKey: key(1),
        text: 'hi',
        timestamp: DateTime(2026),
        isOutgoing: true,
      );
      expect(m.snr, isNull);
      expect(m.rssi, isNull);
      expect(m.isFloodRoute, isNull);
    });

    test('copyWith preserves fields when not overridden', () {
      final m = Message(
        senderKey: key(2),
        text: 'hi',
        timestamp: DateTime(2026),
        isOutgoing: false,
        snr: -3.25,
        isFloodRoute: true,
      );
      final c = m.copyWith(retryCount: 1);
      expect(c.snr, -3.25);
      expect(c.isFloodRoute, isTrue);
      expect(c.rssi, isNull);
    });

    test('copyWith overrides when provided', () {
      final m = Message(
        senderKey: key(3),
        text: 'hi',
        timestamp: DateTime(2026),
        isOutgoing: false,
        snr: 5.0,
        isFloodRoute: false,
      );
      final c = m.copyWith(snr: 9.5, isFloodRoute: true, rssi: -80);
      expect(c.snr, 9.5);
      expect(c.isFloodRoute, isTrue);
      expect(c.rssi, -80);
    });
  });

  group('SNR wire scaling (#438)', () {
    // Firmware sends (int8)(snr_dB * 4); the app recovers dB as byte / 4.0
    // (MyMesh.cpp:512). A naive *4 would be 16x off and out of int8 range.
    double snrFromByte(int b) => b.toSigned(8) / 4.0;

    test('positive SNR', () => expect(snrFromByte(50), 12.5));
    test('zero', () => expect(snrFromByte(0), 0.0));
    test('negative SNR', () => expect(snrFromByte(-13), closeTo(-3.25, 1e-9)));
    test('int8 extremes stay in a sane dB range', () {
      expect(snrFromByte(127), closeTo(31.75, 1e-9));
      expect(snrFromByte(-128), closeTo(-32.0, 1e-9));
    });
  });

  group('flood vs direct discriminator (#438)', () {
    // path_len == 0xFF => direct (routed); anything else => flood N hops.
    bool isFlood(int rawPathLen) => rawPathLen != 0xFF;

    test('0xFF is direct', () => expect(isFlood(0xFF), isFalse));
    test('0 hops is flood, not direct', () => expect(isFlood(0), isTrue));
    test('3 hops is flood', () => expect(isFlood(3), isTrue));
  });
}
