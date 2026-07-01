import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';

void main() {
  group('Channel share URI (#161)', () {
    test('toShareUri matches the reference-app format', () {
      final ch = Channel(
        index: 0,
        name: '#test',
        psk: Channel.parsePskHex('9cd8fcf22a47333b591d96a2b848b73f'),
      );
      expect(
        ch.toShareUri(),
        'meshcore://channel/add?name=%23test&secret=9cd8fcf22a47333b591d96a2b848b73f',
      );
    });

    test('fromShareUri parses a real reference example', () {
      final ch = Channel.fromShareUri(
        'meshcore://channel/add?name=%23echo&secret=5d25cf40b1f5b4a7eb0cf9703634a948',
      );
      expect(ch, isNotNull);
      expect(ch!.name, '#echo');
      expect(ch.pskHex, '5d25cf40b1f5b4a7eb0cf9703634a948');
    });

    test('round-trips name (incl. spaces) + psk', () {
      final ch = Channel(
        index: 3,
        name: 'Private Ops',
        psk: Channel.parsePskHex('0011223344556677889900aabbccddee'),
      );
      final back = Channel.fromShareUri(ch.toShareUri());
      expect(back, isNotNull);
      expect(back!.name, ch.name);
      expect(back.pskHex, ch.pskHex);
    });

    test('rejects malformed / wrong-scheme URIs', () {
      // wrong scheme
      expect(
        Channel.fromShareUri(
          'https://channel/add?name=x&secret=9cd8fcf22a47333b591d96a2b848b73f',
        ),
        isNull,
      );
      // wrong host
      expect(
        Channel.fromShareUri('meshcore://contact/add?name=x&secret=00'),
        isNull,
      );
      // missing secret
      expect(Channel.fromShareUri('meshcore://channel/add?name=x'), isNull);
      // secret not 16 bytes
      expect(
        Channel.fromShareUri('meshcore://channel/add?name=x&secret=abcd'),
        isNull,
      );
      expect(Channel.isValidShareUri('not a uri at all'), isFalse);
    });
  });
}
