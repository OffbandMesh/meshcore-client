import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
