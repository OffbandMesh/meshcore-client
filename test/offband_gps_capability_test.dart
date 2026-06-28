import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('firmwareSupportsOffbandGps', () {
    test('null caps (stock/pre-v14 MeshCore omits the byte) → unsupported', () {
      expect(firmwareSupportsOffbandGps(null), isFalse);
    });

    test('caps byte present with no bits set → supported', () {
      // An Offband v14+ radio that simply isn't a wifi observer still emits the
      // offband_caps byte (value 0), so it speaks the 0xC1 fork extension.
      expect(firmwareSupportsOffbandGps(0x00), isTrue);
    });

    test('caps byte present with bits set → supported', () {
      expect(firmwareSupportsOffbandGps(0x01), isTrue);
      expect(firmwareSupportsOffbandGps(0xFF), isTrue);
    });
  });
}
