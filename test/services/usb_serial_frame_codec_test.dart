import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/usb_serial_frame_codec.dart';

void main() {
  test('wrapUsbSerialTxFrame prefixes tx header and payload length', () {
    final packet = wrapUsbSerialTxFrame(Uint8List.fromList(<int>[0x16, 0x03]));

    expect(
      packet,
      orderedEquals(<int>[usbSerialTxFrameStart, 0x02, 0x00, 0x16, 0x03]),
    );
  });

  test('wrapUsbSerialTxFrame rejects payloads above protocol maximum', () {
    final payload = Uint8List(usbSerialMaxPayloadLength + 1);

    expect(
      () => wrapUsbSerialTxFrame(payload),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'payload.length',
        ),
      ),
    );
  });

  test('UsbSerialFrameDecoder buffers partial frames until complete', () {
    final decoder = UsbSerialFrameDecoder();

    final firstChunk = decoder.ingest(
      Uint8List.fromList(<int>[usbSerialRxFrameStart, 0x03]),
    );
    final secondChunk = decoder.ingest(
      Uint8List.fromList(<int>[0x00, 0x05, 0x06, 0x07]),
    );

    expect(firstChunk, isEmpty);
    expect(secondChunk, hasLength(1));
    expect(secondChunk.single.isRxFrame, isTrue);
    expect(secondChunk.single.payload, orderedEquals(<int>[0x05, 0x06, 0x07]));
  });

  test(
    'UsbSerialFrameDecoder drops leading noise and parses multiple frames',
    () {
      final decoder = UsbSerialFrameDecoder();

      final packets = decoder.ingest(
        Uint8List.fromList(<int>[
          0x00,
          0x01,
          usbSerialRxFrameStart,
          0x01,
          0x00,
          0x55,
          usbSerialRxFrameStart,
          0x02,
          0x00,
          0x66,
          0x77,
        ]),
      );

      expect(packets, hasLength(2));
      expect(packets[0].payload, orderedEquals(<int>[0x55]));
      expect(packets[1].payload, orderedEquals(<int>[0x66, 0x77]));
    },
  );

  test(
    'UsbSerialFrameDecoder preserves tx packets so caller can ignore them',
    () {
      final decoder = UsbSerialFrameDecoder();

      final packets = decoder.ingest(
        Uint8List.fromList(<int>[
          usbSerialTxFrameStart,
          0x01,
          0x00,
          0x22,
          usbSerialRxFrameStart,
          0x01,
          0x00,
          0x33,
        ]),
      );

      expect(packets, hasLength(2));
      expect(packets[0].isRxFrame, isFalse);
      expect(packets[0].payload, orderedEquals(<int>[0x22]));
      expect(packets[1].isRxFrame, isTrue);
      expect(packets[1].payload, orderedEquals(<int>[0x33]));
    },
  );

  test(
    'UsbSerialFrameDecoder drops oversized frames and resyncs on the next valid packet',
    () {
      final decoder = UsbSerialFrameDecoder();

      // A frame claiming a payload above the max must be dropped, and the
      // decoder must resync to the next valid frame. Length is derived from the
      // ceiling so this stays a genuine over-max after it was raised to 176
      // (#430), a hard-coded 173 is now a valid length.
      final oversized = usbSerialMaxPayloadLength + 1;
      final packets = decoder.ingest(
        Uint8List.fromList(<int>[
          usbSerialRxFrameStart,
          oversized & 0xff,
          (oversized >> 8) & 0xff,
          0x99,
          usbSerialRxFrameStart,
          0x01,
          0x00,
          0x44,
        ]),
      );

      expect(packets, hasLength(1));
      expect(packets.single.isRxFrame, isTrue);
      expect(packets.single.payload, orderedEquals(<int>[0x44]));
    },
  );

  test('UsbSerialFrameDecoder reset clears buffered partial data', () {
    final decoder = UsbSerialFrameDecoder();

    expect(
      decoder.ingest(Uint8List.fromList(<int>[usbSerialRxFrameStart, 0x02])),
      isEmpty,
    );

    decoder.reset();

    final packets = decoder.ingest(
      Uint8List.fromList(<int>[usbSerialRxFrameStart, 0x01, 0x00, 0x55]),
    );

    expect(packets, hasLength(1));
    expect(packets.single.payload, orderedEquals(<int>[0x55]));
  });

  test('recovers from invalid frame header', () {
    final decoder = UsbSerialFrameDecoder();

    final packets = decoder.ingest(
      Uint8List.fromList(<int>[
        // First, a malformed frame (e.g. from a partial TX echo)
        usbSerialRxFrameStart,
        usbSerialTxFrameStart,
        // Then, a valid frame
        usbSerialRxFrameStart,
        0x01,
        0x00,
        0x88,
      ]),
    );

    expect(packets, hasLength(1));
    expect(packets.single.isRxFrame, isTrue);
    expect(packets.single.payload, orderedEquals(<int>[0x88]));
  });

  group('skip report (#711): discarded bytes are never silent', () {
    test('clean input reports nothing', () {
      final decoder = UsbSerialFrameDecoder();
      decoder.ingest(
        Uint8List.fromList(<int>[usbSerialRxFrameStart, 0x01, 0x00, 0x55]),
      );

      expect(decoder.takeSkipReport(), isNull);
    });

    test('counts and samples noise before a frame', () {
      final decoder = UsbSerialFrameDecoder();
      final packets = decoder.ingest(
        Uint8List.fromList(<int>[
          0xAA,
          0xBB,
          usbSerialRxFrameStart,
          0x01,
          0x00,
          0x55,
        ]),
      );

      expect(packets.single.payload, orderedEquals(<int>[0x55]));
      final report = decoder.takeSkipReport()!;
      expect(report.count, 2);
      expect(report.sample, orderedEquals(<int>[0xAA, 0xBB]));
      expect(report.describe(), contains('discarded 2 byte(s)'));
      expect(report.describe(), contains('aa bb'));
    });

    test('counts an oversized header and still decodes the next frame', () {
      final decoder = UsbSerialFrameDecoder();
      final oversized = usbSerialMaxPayloadLength + 1;
      final packets = decoder.ingest(
        Uint8List.fromList(<int>[
          usbSerialRxFrameStart,
          oversized & 0xff,
          (oversized >> 8) & 0xff,
          usbSerialRxFrameStart,
          0x01,
          0x00,
          0x44,
        ]),
      );

      expect(packets.single.payload, orderedEquals(<int>[0x44]));
      expect(decoder.takeSkipReport()!.count, 3);
    });

    test('a report is taken once, then cleared', () {
      final decoder = UsbSerialFrameDecoder();
      decoder.ingest(Uint8List.fromList(<int>[0x01, 0x02]));

      expect(decoder.takeSkipReport()!.count, 2);
      expect(decoder.takeSkipReport(), isNull);
    });

    test('the sample is capped, the count is not', () {
      final decoder = UsbSerialFrameDecoder();
      decoder.ingest(Uint8List.fromList(List<int>.filled(40, 0x00)));

      final report = decoder.takeSkipReport()!;
      expect(report.count, 40);
      expect(report.sample, hasLength(16));
      expect(report.describe(), endsWith('...)'));
    });

    test('reset clears a pending report', () {
      final decoder = UsbSerialFrameDecoder();
      decoder.ingest(Uint8List.fromList(<int>[0x01]));
      decoder.reset();

      expect(decoder.takeSkipReport(), isNull);
    });
  });
}
