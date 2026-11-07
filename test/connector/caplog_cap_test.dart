import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('firmwareSupportsOffbandCaplog', () {
    test('true when the 0x20 bit is set', () {
      expect(firmwareSupportsOffbandCaplog(0x20), isTrue);
      expect(firmwareSupportsOffbandCaplog(0x26), isTrue); // block|fem|caplog
    });

    test('false when the caplog bit is missing', () {
      expect(firmwareSupportsOffbandCaplog(0x06), isFalse); // block|fem only
      expect(firmwareSupportsOffbandCaplog(0x00), isFalse);
    });

    test('false when caps are unknown (null)', () {
      expect(firmwareSupportsOffbandCaplog(null), isFalse);
    });

    // #1065: the gate used to AND `FIRMWARE_VER_CODE >= 17` on top of the bit,
    // which went false on the rollback to 14. The version code is no longer a
    // capability signal; the bit is the whole gate and nothing else is read.
    // Stock radios are kept out by the population classifier nulling the caps
    // bytes, not by a floor. See vercode_floor_regression_test.dart.
  });
}
