// #885: mirrors the firmware's `set name` character rejection. Pins exactly
// which characters are forbidden and that detection is order-stable.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/device_name_validator.dart';

void main() {
  group('device name validator (#885)', () {
    test('a clean name is valid', () {
      expect(isValidDeviceName('MyNode-1'), isTrue);
      expect(isValidDeviceName('base camp 2'), isTrue);
      expect(forbiddenCharsIn('MyNode-1'), isEmpty);
    });

    test('an empty name carries no forbidden characters', () {
      expect(isValidDeviceName(''), isTrue);
    });

    test('the forbidden set is exactly these seven characters', () {
      expect(forbiddenDeviceNameChars, ['[', ']', '\\', ':', ',', '?', '*']);
    });

    test('each forbidden character is caught on its own', () {
      for (final c in forbiddenDeviceNameChars) {
        expect(isValidDeviceName('ab${c}cd'), isFalse, reason: c);
        expect(forbiddenCharsIn('ab${c}cd'), [c], reason: c);
      }
    });

    test(
      'a name with no forbidden characters passes, common punctuation ok',
      () {
        expect(isValidDeviceName('Node_42.a-b (home)!'), isTrue);
      },
    );

    test('reports the distinct forbidden characters in canonical order', () {
      // Input order ? , [ ; canonical order is [ , ? .
      expect(forbiddenCharsIn('a?b,c[d'), ['[', ',', '?']);
    });

    test('a repeated forbidden char is reported once', () {
      expect(forbiddenCharsIn('a,,,b'), [',']);
    });
  });
}
