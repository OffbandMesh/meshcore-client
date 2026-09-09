import 'dart:typed_data';

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

  group('Contact share URI emit (#626)', () {
    Contact stub(String name, int type) => Contact(
      publicKey: hex2Uint8List(_key),
      name: name,
      type: type,
      pathLength: -1,
      path: Uint8List(0),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );

    test('buildShareUri emits the documented parameter shape', () {
      expect(
        Contact.buildShareUri(publicKeyHex: _key, name: 'Bob', type: 2),
        'meshcore://contact/add?name=Bob&public_key=$_key&type=2',
      );
    });

    test('type defaults to companion when not supplied', () {
      expect(
        Contact.buildShareUri(publicKeyHex: _key, name: 'Bob'),
        endsWith('&type=$advTypeChat'),
      );
    });

    test('toShareUri round-trips through fromShareUri', () {
      for (final name in [
        'Bob',
        'Two Words',
        'DIRT WIZARD 🧙',
        'amp&equals=hash#q',
        'Ka8sbi',
      ]) {
        final original = stub(name, advTypeRepeater);
        final back = Contact.fromShareUri(original.toShareUri());
        expect(back, isNotNull, reason: 'name "$name" should round-trip');
        expect(back!.name, name);
        expect(back.publicKeyHex, original.publicKeyHex);
        expect(back.type, original.type);
      }
    });

    test('reserved characters in a name are encoded, not emitted raw', () {
      // A raw & or = would silently truncate or forge query parameters.
      final uri = stub('a&b=c', advTypeChat).toShareUri();
      expect(uri.contains('name=a&b=c'), isFalse);
      expect(Contact.fromShareUri(uri)!.name, 'a&b=c');
    });

    test('every documented type survives a round-trip', () {
      for (final t in [
        advTypeChat,
        advTypeRepeater,
        advTypeRoom,
        advTypeSensor,
      ]) {
        expect(Contact.fromShareUri(stub('N', t).toShareUri())!.type, t);
      }
    });

    test('what we emit is what we accept', () {
      expect(
        Contact.isValidShareUri(stub('N', advTypeChat).toShareUri()),
        true,
      );
    });
  });

  group('Compact channel contact share (#611)', () {
    Contact stub(String name, int type) => Contact(
      publicKey: hex2Uint8List(_key),
      name: name,
      type: type,
      pathLength: -1,
      path: Uint8List(0),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );

    test('matches the shape observed on the live mesh', () {
      // Real traffic in #test and #hamradio carries <key:type:name>, with the
      // angle brackets as literal delimiters. Key is synthetic here; the repo
      // is public.
      expect(
        Contact.buildChannelShare(publicKeyHex: _key, name: 'KE8AFF', type: 1),
        '<$_key:1:KE8AFF>',
      );
    });

    test('a name with spaces is carried verbatim', () {
      // One of the two observed samples was "Roger KY4RS".
      expect(
        Contact.buildChannelShare(
          publicKeyHex: _key,
          name: 'Roger KY4RS',
          type: advTypeChat,
        ),
        '<$_key:1:Roger KY4RS>',
      );
    });

    test('angle brackets are stripped from the name', () {
      // A bracket in the name would truncate the payload for every parser
      // reading it, so the emitter must not produce one.
      final out = Contact.buildChannelShare(
        publicKeyHex: _key,
        name: 'we<ird>name',
        type: advTypeChat,
      );
      expect(out, '<$_key:1:weirdname>');
      expect('>'.allMatches(out).length, 1);
      expect('<'.allMatches(out).length, 1);
    });

    test('a colon in the name survives, since the name is the final field', () {
      // A correct parser splits on the first two colons and takes the rest as
      // the name, so this needs no escaping.
      expect(
        Contact.buildChannelShare(
          publicKeyHex: _key,
          name: 'a:b',
          type: advTypeChat,
        ),
        '<$_key:1:a:b>',
      );
    });

    test('every documented type is emitted numerically', () {
      for (final t in [
        advTypeChat,
        advTypeRepeater,
        advTypeRoom,
        advTypeSensor,
      ]) {
        expect(
          Contact.buildChannelShare(publicKeyHex: _key, name: 'N', type: t),
          '<$_key:$t:N>',
        );
      }
    });

    test('toChannelShare uses the contact own key, type and name', () {
      expect(stub('Bob', advTypeRepeater).toChannelShare(), '<$_key:2:Bob>');
    });

    test('what we emit, we can also parse back', () {
      // Without this the app would emit a format it could not itself accept,
      // and pasting our own card into the add dialog would be rejected.
      final c = stub('Roger KY4RS', advTypeRepeater);
      final back = Contact.fromChannelShare(c.toChannelShare());
      expect(back, isNotNull);
      expect(back!.publicKeyHex, _key);
      expect(back.name, 'Roger KY4RS');
      expect(back.type, advTypeRepeater);
      // Same unverified stub as the URI path.
      expect(back.lastSeen, DateTime.fromMillisecondsSinceEpoch(0));
      expect(back.pathLength, -1);
    });

    test('a name containing colons survives the split', () {
      // The name is the final field, so the parser must split on the first two
      // colons only. Splitting on the last one would eat the name.
      final back = Contact.fromChannelShare('<$_key:1:a:b:c>');
      expect(back, isNotNull);
      expect(back!.name, 'a:b:c');
    });

    test('a card embedded in a longer message is still found', () {
      // This is how it actually arrives: someone captions their card.
      final back = Contact.fromChannelShare(
        'here is mine <$_key:1:Bob> add me',
      );
      expect(back, isNotNull);
      expect(back!.name, 'Bob');
    });

    test('emoji and CJK names round-trip', () {
      for (final n in ['DIRT WIZARD 🧙', '中文节点', 'ノード']) {
        final back = Contact.fromChannelShare(
          Contact.buildChannelShare(publicKeyHex: _key, name: n),
        );
        expect(back, isNotNull, reason: 'name "$n" should parse');
        expect(back!.name, n);
      }
    });

    test('rejects malformed cards', () {
      for (final bad in [
        '<$_key:1>', // only one colon
        '<$_key>', // no colons
        '<0011:1:Bob>', // key too short
        '<${_key}ff:1:Bob>', // key too long
        '<${_key.replaceRange(0, 2, 'zz')}:1:Bob>', // not hex
        '<$_key:9:Bob>', // type out of range
        '<$_key:x:Bob>', // type not numeric
        'no brackets at all',
        '',
      ]) {
        expect(
          Contact.fromChannelShare(bad),
          isNull,
          reason: '"$bad" should be rejected',
        );
      }
    });

    test('the compact form is materially cheaper than the URI', () {
      // This is the whole reason both formats exist. Channel text shares a
      // 160-byte payload with the "Sender: " prefix, so the difference is
      // airtime, not tidiness.
      final c = stub('KE8AFF', advTypeChat);
      final compact = c.toChannelShare().length;
      final uri = c.toShareUri().length;
      expect(compact, lessThan(uri));
      expect(uri - compact, greaterThan(30));
    });
  });
}
