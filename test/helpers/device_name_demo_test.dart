// DEMO for #1173 (never merged): a token test that passes on the old code
// too, so test-gate check 2 must refuse it.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/device_name_validator.dart';

void main() {
  test('a short name is valid', () {
    expect(isValidDeviceName('short'), isTrue);
  });
}
