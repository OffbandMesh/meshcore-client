import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

/// A synthetic 64-hex key. Not a real node.
const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

void main() {
  group('Contact share URI (#625)', () {
    test('parses the documented spec example verbatim', () {
      // Straight from the firmware docs/qr_codes.md "Add Contact" example.
      final c = Contact.fromShareUri(
        'meshcore://contact/add'
        '?name=Example+Contact'
        '&public_key=9cd8fcf22a47333b591d96a2b848b73f457b1bb1a3ea2453a885f9e5787765b1'
        '&type=1',
      );
      expect(c, isNotNull);
      // `+` must decode to a space, or stock-emitted names arrive mangled.
      expect(c!.name, 'Example Contact');
      expect(
        c.publicKeyHex,
        '9cd8fcf22a47333b591d96a2b848b73f457b1bb1a3ea2453a885f9e5787765b1',
      );
      expect(c.type, advTypeChat);
    });

    test('percent-encoded names round-trip, including emoji', () {
      final c = Contact.fromShareUri(
        'meshcore://contact/add?name=${Uri.encodeComponent('DIRT WIZARD 🧙')}'
        '&public_key=$_key&type=1',
      );
      expect(c, isNotNull);
      expect(c!.name, 'DIRT WIZARD 🧙');
    });

    test('a parsed contact is an unverified stub, not a routed contact', () {
      final c = Contact.fromShareUri(
        'meshcore://contact/add?name=Bob&public_key=$_key&type=1',
      )!;

      // The load-bearing assertion for #620: lastSeen maps to the firmware's
      // last_advert_timestamp. Anything other than the epoch would trip the
      // advert replay guard and leave this contact permanently deaf to its
      // own adverts.
      expect(c.lastSeen, DateTime.fromMillisecondsSinceEpoch(0));

      // Flood until a path is learned.
      expect(c.pathLength, -1);
      expect(c.path, isEmpty);

      // No signed advert, so it cannot be re-shared yet.
      expect(c.rawPacket, isNull);
      expect(c.flags, 0);
    });

    test('type is optional and defaults to companion', () {
      final c = Contact.fromShareUri(
        'meshcore://contact/add?name=Bob&public_key=$_key',
      );
      expect(c, isNotNull);
      expect(c!.type, advTypeChat);
    });

    test('accepts every documented contact type', () {
      for (final t in [
        advTypeChat,
        advTypeRepeater,
        advTypeRoom,
        advTypeSensor,
      ]) {
        final c = Contact.fromShareUri(
          'meshcore://contact/add?name=N&public_key=$_key&type=$t',
        );
        expect(c, isNotNull, reason: 'type $t should parse');
        expect(c!.type, t);
      }
    });

    test('rejects an out-of-range or non-numeric type', () {
      for (final t in ['0', '5', '255', '-1', 'chat', '1.5']) {
        expect(
          Contact.fromShareUri(
            'meshcore://contact/add?name=N&public_key=$_key&type=$t',
          ),
          isNull,
          reason: 'type "$t" should be rejected',
        );
      }
    });

    test('a missing name falls back rather than failing the add', () {
      final c = Contact.fromShareUri(
        'meshcore://contact/add?public_key=$_key&type=1',
      );
      expect(c, isNotNull);
      expect(c!.name, 'Unknown');
    });

    test('rejects a malformed or wrong-length public key', () {
      final bad = <String>[
        '', // absent value
        '00112233', // too short
        '${_key}ff', // too long
        _key.replaceRange(0, 2, 'zz'), // right length, not hex
      ];
      for (final k in bad) {
        expect(
          Contact.fromShareUri(
            'meshcore://contact/add?name=N&public_key=$k&type=1',
          ),
          isNull,
          reason: 'key "$k" should be rejected',
        );
      }
      // Entirely absent parameter.
      expect(
        Contact.fromShareUri('meshcore://contact/add?name=N&type=1'),
        isNull,
      );
    });

    test('rejects the wrong scheme, host or path', () {
      final bad = <String>[
        'https://contact/add?public_key=$_key',
        'meshcore://channel/add?public_key=$_key',
        'meshcore://contact/remove?public_key=$_key',
        'meshcore://contact?public_key=$_key',
        'not a uri at all',
        '',
      ];
      for (final u in bad) {
        expect(Contact.fromShareUri(u), isNull, reason: '"$u" should reject');
      }
    });

    test('leading and trailing whitespace is tolerated', () {
      expect(
        Contact.fromShareUri(
          '  meshcore://contact/add?name=N&public_key=$_key&type=1\n',
        ),
        isNotNull,
      );
    });

    test(
      'returns null for the legacy advert-hex form so callers fall back',
      () {
        // The fork's older share format is `meshcore://<raw advert hex>`, whose
        // host is the hex itself. It carries a full signed advert and must keep
        // going down its own import path, not this one.
        expect(Contact.fromShareUri('meshcore://${_key}aabbcc'), isNull);
      },
    );

    test('isValidShareUri agrees with fromShareUri', () {
      const good = 'meshcore://contact/add?name=N&public_key=$_key&type=2';
      expect(Contact.isValidShareUri(good), isTrue);
      expect(Contact.isValidShareUri('meshcore://channel/add?name=x'), isFalse);
    });
  });
}
