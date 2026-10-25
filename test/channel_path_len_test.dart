import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/channel_message.dart';

// #985: a 13-hop message with 3-byte path hashes (packed path-len 0x8D)
// rendered as "39 hops". Three defects: the V3 path_len field was read
// signed (0x8D became -115, swallowed as the flood sentinel), the log-RX
// ingress stored the width-stripped hop count, and the repeat merge
// substituted the path BYTE length into the packed field.

Uint8List _v3Frame({required int pathLen, String text = 'Dee3: hi'}) {
  final textBytes = text.codeUnits;
  return Uint8List.fromList([
    respCodeChannelMsgRecvV3,
    0, // SNR
    0, // reserved1 (bit0 = outgoing)
    0, // reserved2
    2, // channel_idx
    pathLen,
    txtTypePlain,
    0x40, 0xE2, 0x01, 0x00, // timestamp LE
    ...textBytes,
  ]);
}

Uint8List _legacyFrame({required int pathLen, String text = 'Dee3: hi'}) {
  final textBytes = text.codeUnits;
  return Uint8List.fromList([
    respCodeChannelMsgRecv,
    2, // channel_idx
    pathLen,
    txtTypePlain,
    0x40, 0xE2, 0x01, 0x00, // timestamp LE
    ...textBytes,
  ]);
}

void main() {
  group('ChannelMessage.fromFrame path-len decode (#985)', () {
    test(
      '3-byte-width packed byte stays unsigned: 0x8D = 13 hops, width 3',
      () {
        final m = ChannelMessage.fromFrame(_v3Frame(pathLen: 0x8D))!;
        expect(m.pathLength, 0x8D);
        expect(m.hopCount, 13);
        expect(m.pathHashSize, 3);
      },
    );

    test('2-byte-width packed byte: 0x53 = 19 hops, width 2', () {
      final m = ChannelMessage.fromFrame(_v3Frame(pathLen: 0x53))!;
      expect(m.hopCount, 19);
      expect(m.pathHashSize, 2);
    });

    test('0xFF stays the direct-route sentinel (-1)', () {
      final m = ChannelMessage.fromFrame(_v3Frame(pathLen: 0xFF))!;
      expect(m.pathLength, -1);
      expect(m.hopCount, -1);
    });

    test('legacy (non-V3) frame decodes the same way', () {
      final m = ChannelMessage.fromFrame(_legacyFrame(pathLen: 0x8D))!;
      expect(m.pathLength, 0x8D);
      expect(m.hopCount, 13);
      expect(m.pathHashSize, 3);
    });
  });

  group('effectivePathHashWidth (#985)', () {
    ChannelMessage msg(int? pathLength) => ChannelMessage(
      senderName: 'Dee3',
      text: 'hi',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      isOutgoing: false,
      status: ChannelMessageStatus.sent,
      pathLength: pathLength,
    );

    test('uses the packet\'s own width when a path-len byte is stored', () {
      expect(msg(0x8D).effectivePathHashWidth(2), 3);
      expect(msg(0x53).effectivePathHashWidth(1), 2);
      expect(msg(13).effectivePathHashWidth(2), 1);
    });

    test('falls back to the device width for legacy/sentinel records', () {
      expect(msg(null).effectivePathHashWidth(2), 2);
      expect(msg(-1).effectivePathHashWidth(3), 3);
      expect(msg(null).effectivePathHashWidth(0), 1);
    });
  });

  group('mergePathLenRaw (#985)', () {
    test('null and sentinel yield to the real packed byte', () {
      expect(mergePathLenRaw(null, 0x8D), 0x8D);
      expect(mergePathLenRaw(0x8D, null), 0x8D);
      expect(mergePathLenRaw(-1, 0x8D), 0x8D);
      expect(mergePathLenRaw(0x8D, -1), 0x8D);
      expect(mergePathLenRaw(null, null), isNull);
    });

    test('higher decoded hop count wins, compared in hops not raw bytes', () {
      // 0x8E = 14 hops at width 3; 0x8D = 13 hops at width 3.
      expect(mergePathLenRaw(0x8D, 0x8E), 0x8E);
      // 19 hops at width 2 (0x53) beats 13 hops at width 2 (0x4D).
      expect(mergePathLenRaw(0x4D, 0x53), 0x53);
      // A width-1 count is NOT outranked by a packed byte's raw magnitude:
      // 20 hops at width 1 beats 13 hops at width 3 (raw 0x8D = 141).
      expect(mergePathLenRaw(0x8D, 20), 20);
    });

    test('regression: the Dee3 scenario decodes to 13 hops, never 39', () {
      // Two repeats of the same packet, both carrying packed 0x8D. The old
      // merge substituted the 39-byte path length, which decoded as
      // "39 hops at width 1".
      final merged = mergePathLenRaw(0x8D, 0x8D)!;
      expect(pathHopCount(merged), 13);
      expect(pathHashSizeBytes(merged), 3);
      expect(pathByteLength(merged), 39);
    });
  });
}
