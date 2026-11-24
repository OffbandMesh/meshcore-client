// DEMO for #1173 (never merged): the only test calls a function the old code
// does not have, so it cannot compile there. Refused for a fix, accepted for
// a feat.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/device_name_validator.dart';

void main() {
  test('a name over 31 characters is too long', () {
    expect(isTooLongDeviceName('x' * 40), isTrue);
  });
}
