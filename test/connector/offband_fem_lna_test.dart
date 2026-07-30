import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('FEM LNA capability gate (#304)', () {
    test('requires the explicit bit, never model or version', () {
      expect(firmwareSupportsOffbandFemLna(offbandCapFemLna), isTrue);
      expect(
        firmwareSupportsOffbandFemLna(offbandCapFemLna | offbandCapBlock),
        isTrue,
      );
    });

    test('false when the bit is clear, even on an Offband radio', () {
      // Offband firmware that supports block but not FEM LNA control.
      expect(firmwareSupportsOffbandFemLna(offbandCapBlock), isFalse);
      expect(firmwareSupportsOffbandFemLna(0x00), isFalse);
    });

    test('false on stock firmware (no caps byte at all)', () {
      expect(firmwareSupportsOffbandFemLna(null), isFalse);
    });

    test('does not collide with the block capability bit', () {
      expect(offbandCapFemLna & offbandCapBlock, equals(0));
    });
  });

  group('FEM LNA device-info state byte, offset 83 (#304)', () {
    Uint8List deviceInfo({required int length, int femByte = 0}) {
      final frame = Uint8List(length);
      frame[0] = respCodeDeviceInfo;
      if (length >= 84) frame[83] = femByte;
      return frame;
    }

    test('reads the byte immediately after caps on v16+', () {
      expect(
        MeshCoreConnector.parseFemLnaState(deviceInfo(length: 84, femByte: 1)),
        isTrue,
      );
      expect(
        MeshCoreConnector.parseFemLnaState(deviceInfo(length: 84, femByte: 0)),
        isFalse,
      );
    });

    test('null on pre-v16 firmware that stops at the caps byte', () {
      expect(
        MeshCoreConnector.parseFemLnaState(deviceInfo(length: 83)),
        isNull,
      );
      expect(MeshCoreConnector.parseFemLnaState(Uint8List(0)), isNull);
    });

    test('does not disturb the caps byte at offset 82', () {
      final frame = deviceInfo(length: 84, femByte: 1);
      frame[82] = offbandCapBlock | offbandCapFemLna;
      expect(MeshCoreConnector.parseOffbandCaps(frame), equals(0x06));
      expect(MeshCoreConnector.parseFemLnaState(frame), isTrue);
    });

    test('byte is present on non-capable boards and reads as bypassed', () {
      // Firmware appends it unconditionally, so presence indicates version,
      // not capability, the cap bit is what gates the UI.
      final frame = deviceInfo(length: 84, femByte: 0);
      frame[82] = 0x00;
      expect(MeshCoreConnector.parseFemLnaState(frame), isFalse);
      expect(
        firmwareSupportsOffbandFemLna(
          MeshCoreConnector.parseOffbandCaps(frame),
        ),
        isFalse,
      );
    });
  });

  group('FEM LNA frames (#304)', () {
    test('SET carries the enable value', () {
      expect(
        buildOffbandFemLnaSetFrame(true),
        equals(Uint8List.fromList([0xC3, 0x01, 0x01])),
      );
      expect(
        buildOffbandFemLnaSetFrame(false),
        equals(Uint8List.fromList([0xC3, 0x01, 0x00])),
      );
    });

    test('GET is a bare 2-byte request', () {
      expect(
        buildOffbandFemLnaGetFrame(),
        equals(Uint8List.fromList([0xC3, 0x02])),
      );
    });

    test('reply parses sub-type and value', () {
      final reply = parseOffbandFemLnaReply(
        Uint8List.fromList([0xC3, 0x02, 0x01]),
      );
      expect(reply, isNotNull);
      expect(reply!.subType, equals(offbandFemLnaGet));
      expect(reply.enabled, isTrue);

      final bypassed = parseOffbandFemLnaReply(
        Uint8List.fromList([0xC3, 0x02, 0x00]),
      );
      expect(bypassed!.enabled, isFalse);
    });

    test('rejects a short frame instead of throwing', () {
      expect(parseOffbandFemLnaReply(Uint8List.fromList([0xC3, 0x02])), isNull);
      expect(parseOffbandFemLnaReply(Uint8List.fromList([])), isNull);
    });

    test('ignores frames belonging to another command', () {
      // The generic error reply is [0x01][0x06] and is NOT 0xC3-prefixed, so it
      // must never be mistaken for a FEM LNA reply.
      expect(
        parseOffbandFemLnaReply(
          Uint8List.fromList([respCodeErr, errCodeIllegalArg]),
        ),
        isNull,
      );
      expect(
        parseOffbandFemLnaReply(Uint8List.fromList([0xC2, 0x01, 0x01])),
        isNull,
      );
    });
  });
}
