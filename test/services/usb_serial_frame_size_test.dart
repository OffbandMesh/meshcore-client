import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_serial_frame_codec.dart';

/// Wrap [payload] as an inbound (RX) transport frame: [0x3e, len_lo, len_hi, …].
Uint8List _rxFrame(Uint8List payload) => Uint8List.fromList([
  usbSerialRxFrameStart,
  payload.length & 0xff,
  (payload.length >> 8) & 0xff,
  ...payload,
]);

void main() {
  group('UsbSerialFrameDecoder frame-size boundary (#430)', () {
    test('accepts a full 176-byte companion frame (caplog chunk)', () {
      // Regression: 172 used to reject this, dropping every full caplog chunk.
      final payload = Uint8List(176)..fillRange(0, 176, 0xAB);
      final packets = UsbSerialFrameDecoder().ingest(_rxFrame(payload));
      expect(packets, hasLength(1));
      expect(packets.single.payload.length, 176);
    });

    test('decodes 30 full chunks batched into one read (caplog stream)', () {
      final buf = <int>[];
      for (var i = 0; i < 30; i++) {
        buf.addAll(_rxFrame(Uint8List(176)..fillRange(0, 176, i)));
      }
      final packets = UsbSerialFrameDecoder().ingest(Uint8List.fromList(buf));
      expect(packets, hasLength(30));
      expect(packets.every((p) => p.payload.length == 176), isTrue);
    });

    test('still rejects an over-max (177-byte) frame', () {
      final packets = UsbSerialFrameDecoder().ingest(_rxFrame(Uint8List(177)));
      expect(packets, isEmpty);
    });
  });
}
