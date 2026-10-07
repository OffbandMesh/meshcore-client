import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/region_key.dart';

// Known-answer vectors computed with an independent implementation
// (Python hashlib). The firmware derives a region's transport key as the
// first 16 bytes of SHA256 of the hashtag name WITH exactly one leading '#'
// (firmware: RegionMap.getTransportKeysFor -> TransportKeyStore.getAutoKeyFor,
// which hashes the stored name; bare names get '#' prepended). Discovered
// region names arrive '#'-stripped, so the client re-adds the '#'.
String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('transportKeyForName', () {
    test('first 16 bytes of SHA256("#"+name) for a bare name', () {
      expect(
        _hex(transportKeyForName('oki')!),
        '599fe2546002709fa493b15de58bdd0d',
      );
      expect(
        _hex(transportKeyForName('test')!),
        '9cd8fcf22a47333b591d96a2b848b73f',
      );
    });

    test('idempotent on a leading # (auto-hashtag names hash as-is)', () {
      expect(
        _hex(transportKeyForName('#oki')!),
        _hex(transportKeyForName('oki')!),
      );
    });

    test('key is 16 bytes', () {
      expect(transportKeyForName('oki')!.length, 16);
    });

    test('private (\$-prefixed) regions are not name-derivable', () {
      expect(isPrivateRegionName(r'$secret'), isTrue);
      expect(transportKeyForName(r'$secret'), isNull);
    });

    test('empty or blank name yields no key', () {
      expect(transportKeyForName(''), isNull);
      expect(transportKeyForName('   '), isNull);
    });
  });

  group('onAirCode', () {
    test('matches the firmware HMAC transport code (little-endian uint16)', () {
      final key = transportKeyForName('oki')!;
      final code = onAirCode(
        key,
        0x00,
        Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
      );
      expect(code, 0x959d);
    });

    test('reserves codes 0x0000 and 0xFFFF', () {
      // Both reserved values are bumped by one, matching
      // TransportKey::calcTransportCode in firmware.
      expect(reserveTransportCode(0x0000), 0x0001);
      expect(reserveTransportCode(0xFFFF), 0xFFFE);
      expect(reserveTransportCode(0x1234), 0x1234);
    });
  });
}
