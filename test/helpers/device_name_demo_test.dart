// DEMO for #1173 (never merged): a real regression test. The old code
// accepts a 40-character name, so this fails there and test-gate passes.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/device_name_validator.dart';

void main() {
  test('a name over 31 characters is refused', () {
    expect(isValidDeviceName('x' * 40), isFalse);
  });
}
