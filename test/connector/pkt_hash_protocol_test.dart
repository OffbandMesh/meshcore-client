import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('0xC6 pkt-hash builder', () {
    test('builds a 7-byte GET with little-endian timestamp', () {
      final frame = buildOffbandPktHashGetFrame(0x11223344, 7);
      expect(frame, [0xC6, 0x01, 0x44, 0x33, 0x22, 0x11, 0x07]);
    });

    test('masks channel_idx to one byte', () {
      final frame = buildOffbandPktHashGetFrame(0, 0x1FF);
      expect(frame[6], 0xFF);
    });
  });

  group('0xC6 pkt-hash reply parser', () {
    Uint8List reply(int ts, int chan, List<int> hash8) {
      final f = Uint8List(15);
      f[0] = cmdOffbandPktHash;
      f[1] = pktHashRespGet;
      ByteData.sublistView(f, 2, 6).setUint32(0, ts, Endian.little);
      f[6] = chan;
      f.setRange(7, 15, hash8);
      return f;
    }

    test('parses a success reply and echoes the key', () {
      final parsed = parseOffbandPktHashReply(
        reply(0x11223344, 3, [0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x0a, 0xff]),
      );
      expect(parsed, isNotNull);
      expect(parsed!.timestamp, 0x11223344);
      expect(parsed.channelIdx, 3);
      // 16 lowercase hex chars, matching CoreScope + client _computePacketHash.
      expect(parsed.hashHex, 'deadbeef01020aff');
    });

    test('returns null on the error reply', () {
      final err = Uint8List.fromList([cmdOffbandPktHash, pktHashRespErr, 1]);
      expect(parseOffbandPktHashReply(err), isNull);
    });

    test('returns null on a short/malformed frame', () {
      expect(
        parseOffbandPktHashReply(Uint8List.fromList([0xC6, 0x01, 0, 0])),
        isNull,
      );
      expect(parseOffbandPktHashReply(Uint8List(0)), isNull);
    });

    test('returns null when the opcode is wrong', () {
      final f = reply(1, 1, List.filled(8, 0));
      f[0] = 0xC4; // caplog, not pkt-hash
      expect(parseOffbandPktHashReply(f), isNull);
    });
  });

  group('firmwareSupportsPktHash gate', () {
    test('requires both the cap bit and ver >= 22', () {
      expect(firmwareSupportsPktHash(0x08, 22), isTrue);
      expect(firmwareSupportsPktHash(0x08, 23), isTrue);
      expect(firmwareSupportsPktHash(0x08, 21), isFalse); // version too low
      expect(firmwareSupportsPktHash(0x00, 22), isFalse); // bit clear
      expect(firmwareSupportsPktHash(null, 22), isFalse); // no byte 2
      expect(firmwareSupportsPktHash(0x08, null), isFalse); // no version
    });

    test('ignores unrelated bits', () {
      // 0x0A = button-matrix (0x02) + pkt-hash (0x08) both set.
      expect(firmwareSupportsPktHash(0x0A, 22), isTrue);
      // Only notify-scope (0x01) set: pkt-hash bit clear.
      expect(firmwareSupportsPktHash(0x01, 22), isFalse);
    });
  });
}
