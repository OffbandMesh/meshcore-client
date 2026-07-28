import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('caplog control frames', () {
    test('builders emit the right command + sub-code', () {
      expect(buildOffbandCaplogRequestFrame(), Uint8List.fromList([0xC4]));
      expect(buildOffbandCaplogEnableFrame(), Uint8List.fromList([0xC4, 0x02]));
      expect(
        buildOffbandCaplogDisableFrame(),
        Uint8List.fromList([0xC4, 0x03]),
      );
      expect(buildOffbandCaplogEraseFrame(), Uint8List.fromList([0xC4, 0x04]));
      expect(buildOffbandCaplogStatusFrame(), Uint8List.fromList([0xC4, 0x05]));
    });

    test('parseCaplogAck reads req_op + ok', () {
      final ack = parseCaplogAck(
        Uint8List.fromList([0xC4, caplogRespAck, caplogReqEnable, 1]),
      );
      expect(ack, isNotNull);
      expect(ack!.reqOp, caplogReqEnable);
      expect(ack.ok, isTrue);

      final fail = parseCaplogAck(
        Uint8List.fromList([0xC4, caplogRespAck, caplogReqErase, 0]),
      );
      expect(fail!.ok, isFalse);
    });

    test('parseCaplogAck rejects non-ack / short / wrong-code frames', () {
      // A download START frame (sub 0x01) is not an ACK.
      expect(
        parseCaplogAck(Uint8List.fromList([0xC4, caplogSubStart, 0, 0, 0, 0])),
        isNull,
      );
      // Wrong command byte.
      expect(
        parseCaplogAck(Uint8List.fromList([0x00, caplogRespAck, 0, 1])),
        isNull,
      );
      // Too short (missing ok byte).
      expect(
        parseCaplogAck(Uint8List.fromList([0xC4, caplogRespAck, 2])),
        isNull,
      );
    });

    test('parseCaplogStatus reads enabled/level/used/cap little-endian', () {
      final frame = Uint8List.fromList([
        0xC4, caplogRespStatus,
        1, // enabled
        4, // level
        0x02, 0x01, 0x00, 0x00, // used = 258
        0x00, 0x20, 0x00, 0x00, // capacity = 8192
      ]);
      final s = parseCaplogStatus(frame);
      expect(s, isNotNull);
      expect(s!.enabled, isTrue);
      expect(s.level, 4);
      expect(s.usedBytes, 258);
      expect(s.capacityBytes, 8192);
    });

    test('parseCaplogStatus rejects non-status / short frames', () {
      expect(
        parseCaplogStatus(Uint8List.fromList([0xC4, caplogRespAck, 2, 1])),
        isNull,
      );
      expect(
        parseCaplogStatus(
          Uint8List.fromList([0xC4, caplogRespStatus, 1, 4, 0, 0]),
        ),
        isNull,
      );
    });
  });
}
