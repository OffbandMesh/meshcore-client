import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/crockford_base32.dart';

void main() {
  group('CrockfordBase32', () {
    group('encode5', () {
      test('encodes 40 zero bits', () {
        expect(CrockfordBase32.encode5([0, 0, 0, 0, 0]), '00000000');
      });

      test('encodes 40 one bits', () {
        expect(CrockfordBase32.encode5([255, 255, 255, 255, 255]), 'zzzzzzzz');
      });

      test('walks the alphabet in order, most significant group first', () {
        // 0x004432 14c7 packs the 5-bit groups 0,1,2,3,4,5,6,7.
        expect(
          CrockfordBase32.encode5([0x00, 0x44, 0x32, 0x14, 0xc7]),
          '01234567',
        );
      });

      test('encodes a value above 32 bits without truncating', () {
        // Guards the web target, where a naive 40-bit shift would lose the top
        // byte and return '0...' for this input.
        expect(
          CrockfordBase32.encode5([0x8f, 0x1e, 0x2d, 0x00, 0x01]),
          'hwf2t001',
        );
      });

      test('rejects anything that is not exactly 5 bytes', () {
        expect(
          () => CrockfordBase32.encode5([1, 2, 3, 4]),
          throwsArgumentError,
        );
        expect(
          () => CrockfordBase32.encode5([1, 2, 3, 4, 5, 6]),
          throwsArgumentError,
        );
      });
    });

    group('normalize8', () {
      test('passes a canonical hash through unchanged', () {
        expect(CrockfordBase32.normalize8('dyps6yf0'), 'dyps6yf0');
      });

      test('lowercases', () {
        expect(CrockfordBase32.normalize8('DYPS6YF0'), 'dyps6yf0');
      });

      test('resolves the ambiguity aliases in both cases', () {
        expect(CrockfordBase32.normalize8('OoIiLl00'), '00111100');
      });

      test('rejects u, which has no alias', () {
        expect(CrockfordBase32.normalize8('dypsuyf0'), isNull);
        expect(CrockfordBase32.normalize8('dypsUyf0'), isNull);
      });

      test('rejects the wrong length', () {
        expect(CrockfordBase32.normalize8('dyps6yf'), isNull);
        expect(CrockfordBase32.normalize8('dyps6yf00'), isNull);
        expect(CrockfordBase32.normalize8(''), isNull);
      });

      test('rejects non-alphabet characters', () {
        expect(CrockfordBase32.normalize8('dyps6y-0'), isNull);
        expect(CrockfordBase32.normalize8('dyps6y 0'), isNull);
      });

      test('the alphabet omits the ambiguous letters', () {
        for (final c in ['i', 'l', 'o', 'u']) {
          expect(
            CrockfordBase32.alphabet.contains(c),
            isFalse,
            reason: 'alphabet must not contain $c',
          );
        }
        expect(CrockfordBase32.alphabet.length, 32);
      });
    });
  });
}
