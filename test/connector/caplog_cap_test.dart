import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('firmwareSupportsOffbandCaplog', () {
    test('true when 0x20 bit set AND version >= 17', () {
      expect(firmwareSupportsOffbandCaplog(0x20, 17), isTrue);
      expect(
        firmwareSupportsOffbandCaplog(0x26, 17),
        isTrue,
      ); // block|fem|caplog
      expect(firmwareSupportsOffbandCaplog(0x20, 18), isTrue);
    });

    test('false when the caplog bit is missing', () {
      expect(
        firmwareSupportsOffbandCaplog(0x06, 17),
        isFalse,
      ); // block|fem only
      expect(firmwareSupportsOffbandCaplog(0x00, 17), isFalse);
    });

    test('false when version is below 17', () {
      expect(firmwareSupportsOffbandCaplog(0x20, 16), isFalse);
      expect(firmwareSupportsOffbandCaplog(0x20, null), isFalse);
    });

    test('false when caps are unknown (null)', () {
      expect(firmwareSupportsOffbandCaplog(null, 17), isFalse);
    });
  });
}
