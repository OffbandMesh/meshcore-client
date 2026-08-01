import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  /// Device-info frame with the three additive tail bytes at their fixed
  /// absolute offsets: caps byte 1 at 82, FEM LNA state at 83, caps byte 2 at
  /// 84 (firmware #508 / PR #515).
  Uint8List deviceInfo({
    required int length,
    int caps1 = 0,
    int femByte = 0,
    int caps2 = 0,
  }) {
    final frame = Uint8List(length);
    if (length >= 1) frame[0] = respCodeDeviceInfo;
    if (length >= 83) frame[82] = caps1;
    if (length >= 84) frame[83] = femByte;
    if (length >= 85) frame[84] = caps2;
    return frame;
  }

  group('offband_caps byte 2, device-info offset 84 (#480)', () {
    test('reads byte 84 when the frame is long enough', () {
      expect(
        MeshCoreConnector.parseOffbandCaps2(
          deviceInfo(length: 85, caps2: 0x01),
        ),
        equals(0x01),
      );
      expect(
        MeshCoreConnector.parseOffbandCaps2(
          deviceInfo(length: 85, caps2: 0xFF),
        ),
        equals(0xFF),
      );
    });

    test('a present byte 2 of zero is still present, not absent', () {
      // "No byte-2 capabilities set" and "firmware predates byte 2" are
      // different states; only the second is null.
      expect(
        MeshCoreConnector.parseOffbandCaps2(deviceInfo(length: 85, caps2: 0)),
        equals(0),
      );
    });

    test('null on firmware predating #508 (frame stops at 84)', () {
      expect(
        MeshCoreConnector.parseOffbandCaps2(deviceInfo(length: 84)),
        isNull,
      );
    });

    test('null on a short or truncated frame, never an OOB index', () {
      for (final length in [0, 1, 4, 81, 82, 83, 84]) {
        expect(
          MeshCoreConnector.parseOffbandCaps2(deviceInfo(length: length)),
          isNull,
          reason: 'frame length $length must yield null, not throw',
        );
      }
    });
  });

  group('byte 2 does not disturb the fields before it', () {
    // This is the regression the offset-84 choice exists to prevent: byte 2 is
    // appended at the END of the frame, not adjacent to byte 1, because the FEM
    // state byte already occupies 83 and every field is read at a fixed
    // absolute offset.
    final frame = deviceInfo(
      length: 85,
      caps1: offbandCapFemLna | offbandCapBlock,
      femByte: 1,
      caps2: 0x03,
    );

    test('caps byte 1 still reads at offset 82', () {
      expect(
        MeshCoreConnector.parseOffbandCaps(frame),
        equals(offbandCapFemLna | offbandCapBlock),
      );
    });

    test('FEM LNA state still reads at offset 83', () {
      expect(MeshCoreConnector.parseFemLnaState(frame), isTrue);
    });

    test('byte-1 gate predicates are unaffected by byte 2', () {
      final caps1 = MeshCoreConnector.parseOffbandCaps(frame);
      expect(firmwareSupportsOffbandFemLna(caps1), isTrue);
      expect(firmwareSupportsOffbandBlock(caps1, 15), isTrue);
    });

    test('all three tail fields are independent', () {
      final onlyCaps2 = deviceInfo(length: 85, caps2: 0x02);
      expect(MeshCoreConnector.parseOffbandCaps(onlyCaps2), equals(0));
      expect(MeshCoreConnector.parseFemLnaState(onlyCaps2), isFalse);
      expect(MeshCoreConnector.parseOffbandCaps2(onlyCaps2), equals(0x02));
    });
  });
}
