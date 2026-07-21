// Path-len byte encode/decode (#309, supersedes #112/#222).
//
// The firmware path-len byte is PACKED and self-describing:
//   high 2 bits = hash size - 1 (1..3 bytes per hop hash)
//   low  6 bits = hash COUNT, i.e. the number of HOPS
//   byte length = count * size
//
// Verified against firmware src/Packet.h:79-84:
//   getPathHashSize()  == (path_len >> 6) + 1
//   getPathHashCount() == path_len & 63
//   getPathByteLen()   == getPathHashCount() * getPathHashSize()
//   setPathHashSizeAndCount(sz, n) { path_len = ((sz - 1) << 6) | (n & 63); }
//
// This file previously asserted the opposite (low 6 bits = a BYTE count, and a
// realHopCount() that divided by the device width). Those assertions encoded the
// bug: the app read `count` bytes where firmware meant `count` hops, keeping
// half of every path at 2-byte width, and halved every displayed hop count.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('path-len decode', () {
    test('low 6 bits are a HOP count, not a byte count', () {
      // 0x42 = 2-byte hashes, 2 hops. The old model called this "2 bytes".
      expect(pathHopCount(0x42), 2);
      expect(pathHashSizeBytes(0x42), 2);
      expect(pathByteLength(0x42), 4); // 2 hops * 2 bytes
    });

    test('one 2-byte hop is 1 hop occupying 2 bytes', () {
      // Bandit's C65C case: ONE hop through a 2-byte-prefixed repeater.
      expect(pathHopCount(0x41), 1);
      expect(pathHashSizeBytes(0x41), 2);
      expect(pathByteLength(0x41), 2);
    });

    test('1-byte width is unchanged (legacy nets)', () {
      expect(pathHopCount(0x03), 3);
      expect(pathHashSizeBytes(0x03), 1);
      expect(pathByteLength(0x03), 3);
    });

    test('3-byte width', () {
      // 0x82 = size 3, 2 hops -> 6 bytes.
      expect(pathHashSizeBytes(0x82), 3);
      expect(pathHopCount(0x82), 2);
      expect(pathByteLength(0x82), 6);
    });

    test('direct (zero-hop) at 2-byte mode carries no path bytes', () {
      // 0x40 = size 2, 0 hops. Reading the raw byte as a length would have
      // pulled 64 junk bytes into the path.
      expect(pathHopCount(0x40), 0);
      expect(pathByteLength(0x40), 0);
    });
  });

  group('encodePathLen', () {
    test('packs width and hop count the way firmware does', () {
      expect(encodePathLen(2, 2), 0x42);
      expect(encodePathLen(1, 2), 0x41);
      expect(encodePathLen(3, 1), 0x03);
      expect(encodePathLen(2, 3), 0x82);
      expect(encodePathLen(0, 2), 0x40);
    });

    test('round-trips through the decoders', () {
      for (final width in [1, 2, 3]) {
        for (final hops in [0, 1, 5, 63]) {
          final encoded = encodePathLen(hops, width);
          expect(pathHopCount(encoded), hops, reason: 'hops w=$width');
          expect(pathHashSizeBytes(encoded), width, reason: 'width w=$width');
        }
      }
    });

    test('clamps width to the 1..3 firmware range (mode 3 is reserved)', () {
      expect(pathHashSizeBytes(encodePathLen(1, 0)), 1);
      expect(pathHashSizeBytes(encodePathLen(1, 9)), 3);
    });

    test('a bare hop count would mislabel the width as 1 byte', () {
      // The send-side bug: writing the count raw leaves mode bits 00, telling
      // the radio "1-byte hashes" while handing it 2-byte hash data.
      const rawCount = 2;
      expect(pathHashSizeBytes(rawCount), 1); // what the radio would have read
      expect(pathHashSizeBytes(encodePathLen(2, 2)), 2); // what it must read
    });
  });
}
