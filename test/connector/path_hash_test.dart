// Path-hash width / hop-count decode (#112). The firmware path-length byte is a
// BYTE count of the hop-hash array, not a hop count, so at a 2-byte hash width a
// single 2-byte hop reports 2. realHopCount divides by the device width to get
// true hops; the Packet Path screen slices and matches at the device width so a
// 2-byte hash like 6A3D resolves to one repeater instead of two 1-byte hops.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('realHopCount', () {
    test('divides path byte-length by hash width', () {
      // The bug: one 2-byte hop (6A3D) reported byteLen 2 -> shown as "2 hops".
      expect(realHopCount(2, 2), 1);
      expect(realHopCount(4, 2), 2);
      expect(realHopCount(6, 3), 2);
    });

    test('is a no-op at 1-byte width (no regression for legacy nets)', () {
      expect(realHopCount(3, 1), 3);
    });

    test('treats width < 1 as 1', () {
      expect(realHopCount(3, 0), 3);
    });

    test('passes null (unknown) and negative (flood) sentinels through', () {
      expect(realHopCount(null, 2), isNull);
      expect(realHopCount(-1, 2), -1);
    });
  });
}
