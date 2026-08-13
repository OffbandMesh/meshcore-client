import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/stock_config.dart';

/// All key material in this file is synthetic and obviously fake. Real stock
/// exports carry a live node private key and channel PSKs and must never enter
/// the repository (#568).
const String fakePublicKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String fakePrivateKey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// 32 hex characters = the 16-byte channel PSK.
const String fakeChannelSecret = 'cccccccccccccccccccccccccccccccc';

Map<String, dynamic> contactJson({
  String name = 'Node',
  String? customName,
  String publicKey = fakePublicKey,
  int type = 1,
  int flags = 0,
  String latitude = '0.0',
  String longitude = '0.0',
  int lastAdvert = 1785706493,
  int lastModified = 1785706508,
  Object? outPathList,
}) => {
  'type': type,
  'name': name,
  'custom_name': customName,
  'public_key': publicKey,
  'flags': flags,
  'latitude': latitude,
  'longitude': longitude,
  'last_advert': lastAdvert,
  'last_modified': lastModified,
  'out_path_list': outPathList,
};

Map<String, dynamic> fullConfigJson() => {
  'name': 'Test Radio',
  'public_key': fakePublicKey,
  'private_key': fakePrivateKey,
  'radio_settings': {
    'frequency': 910525,
    'bandwidth': 62500,
    'spreading_factor': 7,
    'coding_rate': 5,
    'tx_power': 22,
  },
  'position_settings': {'latitude': '39.561991', 'longitude': '-84.635731'},
  'other_settings': {'manual_add_contacts': 1, 'advert_location_policy': 0},
  'auto_add_settings': {
    'auto_add_chat': true,
    'auto_add_repeater': true,
    'auto_add_room_server': false,
    'auto_add_sensor': false,
    'overwrite_oldest': true,
    'auto_add_max_hops': 0,
  },
  'channels': [
    {'name': 'Public', 'secret': fakeChannelSecret},
  ],
  'contacts': [contactJson()],
};

void main() {
  group('round trip', () {
    test('a full config survives parse then encode unchanged', () {
      final source = jsonEncode(fullConfigJson());

      final reencoded = StockConfig.parse(source).encode();

      expect(jsonDecode(reencoded), fullConfigJson());
    });

    test('radio settings keep their raw values and units', () {
      final radio = StockConfig.parse(
        jsonEncode(fullConfigJson()),
      ).radioSettings!;

      // frequency is kHz, bandwidth is Hz, coding_rate is a bare denominator.
      expect(radio.frequencyKhz, 910525);
      expect(radio.bandwidthHz, 62500);
      expect(radio.codingRate, 5);
    });

    test('coordinates are emitted as strings, never numbers', () {
      final encoded =
          jsonDecode(StockConfig.parse(jsonEncode(fullConfigJson())).encode())
              as Map<String, dynamic>;

      expect(encoded['position_settings']['latitude'], isA<String>());
      expect(encoded['position_settings']['latitude'], '39.561991');
      expect((encoded['contacts'] as List).first['latitude'], '0.0');
    });
  });

  group('optional sections', () {
    test('a config with no sections at all parses to all nulls', () {
      final config = StockConfig.parse('{}');

      expect(config.name, isNull);
      expect(config.publicKey, isNull);
      expect(config.channels, isNull);
      expect(config.contacts, isNull);
    });

    test('an identity-only export parses, mirroring stock 272-byte files', () {
      final config = StockConfig.parse(
        jsonEncode({
          'name': 'Test Radio',
          'public_key': fakePublicKey,
          'private_key': fakePrivateKey,
        }),
      );

      expect(config.name, 'Test Radio');
      expect(config.privateKey, hasLength(64));
      expect(config.radioSettings, isNull);
      expect(config.contacts, isNull);
    });

    test(
      'identity deselected omits both key fields, not just the private one',
      () {
        final json = fullConfigJson()
          ..remove('public_key')
          ..remove('private_key');

        final encoded =
            jsonDecode(StockConfig.parse(jsonEncode(json)).encode())
                as Map<String, dynamic>;

        expect(encoded.containsKey('public_key'), isFalse);
        expect(encoded.containsKey('private_key'), isFalse);
      },
    );

    test('a public key without a private key is still accepted', () {
      // Observed in a 2026-08-07 export, a combination current stock does not
      // produce. The format has no version field, so the reader tolerates it.
      final json = fullConfigJson()..remove('private_key');

      final config = StockConfig.parse(jsonEncode(json));

      expect(config.publicKey, hasLength(32));
      expect(config.privateKey, isNull);
    });

    test('absent sections are omitted rather than written as null', () {
      final encoded =
          jsonDecode(const StockConfig(name: 'Bare').encode())
              as Map<String, dynamic>;

      expect(encoded.keys, ['name']);
    });

    test('an empty contact list is distinct from an absent one', () {
      expect(StockConfig.parse('{"contacts":[]}').contacts, isEmpty);
      expect(StockConfig.parse('{}').contacts, isNull);
    });

    test('unknown top-level keys are ignored, not rejected', () {
      final json = fullConfigJson()..['some_future_section'] = {'a': 1};

      expect(StockConfig.parse(jsonEncode(json)).name, 'Test Radio');
    });
  });

  group('channels', () {
    test('array position is the index, since records carry none', () {
      final config = StockConfig.parse(
        jsonEncode({
          'channels': [
            {'name': 'First', 'secret': fakeChannelSecret},
            {'name': 'Second', 'secret': fakeChannelSecret},
          ],
        }),
      );

      expect(config.channels!.map((c) => c.name), ['First', 'Second']);
      expect(config.channels!.first.secret, hasLength(16));
    });

    test('a secret of the wrong length is rejected with its path', () {
      expect(
        () => StockConfig.parse('{"channels":[{"name":"X","secret":"aabb"}]}'),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'channels[0].secret',
          ),
        ),
      );
    });
  });

  group('contacts', () {
    test('a 25-character name round trips', () {
      final name = 'A' * 25;
      final json = {
        'contacts': [contactJson(name: name)],
      };

      expect(StockConfig.parse(jsonEncode(json)).contacts!.first.name, name);
    });

    test('serializing a name longer than the firmware cap throws', () {
      final config = StockConfig.parse(
        jsonEncode({
          'contacts': [contactJson(name: 'A' * 32)],
        }),
      );

      expect(config.encode, throwsA(isA<StockConfigFormatException>()));
    });

    test('an implausible far-future timestamp is preserved, not sanitized', () {
      // The reference corpus contains values up to the year 2095.
      final json = {
        'contacts': [contactJson(lastAdvert: 3950815473, lastModified: 14)],
      };

      final contact = StockConfig.parse(jsonEncode(json)).contacts!.first;

      expect(contact.lastAdvert, 3950815473);
      expect(contact.lastModified, 14);
    });

    test('flags bit 0 decodes as favourite', () {
      final json = {
        'contacts': [contactJson(flags: 15), contactJson(flags: 0)],
      };

      final contacts = StockConfig.parse(jsonEncode(json)).contacts!;

      expect(contacts[0].isFavourite, isTrue);
      expect(contacts[1].isFavourite, isFalse);
    });

    test('a null custom name round trips as null', () {
      final config = StockConfig.parse(
        jsonEncode({
          'contacts': [contactJson()],
        }),
      );

      expect(config.contacts!.first.customName, isNull);
      expect(
        (jsonDecode(config.encode())['contacts'] as List).first['custom_name'],
        isNull,
      );
    });
  });

  group('out_path_list', () {
    test('null and empty string both mean no path', () {
      final json = {
        'contacts': [
          contactJson(outPathList: null),
          contactJson(outPathList: ''),
        ],
      };

      final contacts = StockConfig.parse(jsonEncode(json)).contacts!;

      expect(contacts[0].outPath, isNull);
      expect(contacts[1].outPath!.hopCount, 0);
    });

    test('the null and empty-string forms stay distinct on re-encode', () {
      // Real exports contain both. We do not know what distinguishes them, so
      // collapsing them would discard information we cannot recover.
      final json = {
        'contacts': [
          contactJson(outPathList: null),
          contactJson(outPathList: ''),
        ],
      };

      final encoded =
          jsonDecode(StockConfig.parse(jsonEncode(json)).encode())['contacts']
              as List;

      expect(encoded[0]['out_path_list'], isNull);
      expect(encoded[1]['out_path_list'], '');
    });

    test('a width-2 path yields hop count and width without inference', () {
      // The only populated path in the reference corpus: two hops, four hex
      // characters each.
      final json = {
        'contacts': [contactJson(outPathList: 'a1b2,c3d4')],
      };

      final path = StockConfig.parse(jsonEncode(json)).contacts!.first.outPath!;

      expect(path.hashWidth, 2);
      expect(path.hopCount, 2);
      expect(path.bytes, [0xa1, 0xb2, 0xc3, 0xd4]);
    });

    test('width 1 and width 3 parse even though only width 2 was observed', () {
      Map<String, dynamic> one(String p) => {
        'contacts': [contactJson(outPathList: p)],
      };

      final narrow = StockConfig.parse(
        jsonEncode(one('a1,b2,c3')),
      ).contacts!.first.outPath!;
      final wide = StockConfig.parse(
        jsonEncode(one('a1b2c3')),
      ).contacts!.first.outPath!;

      expect(narrow.hashWidth, 1);
      expect(narrow.hopCount, 3);
      expect(wide.hashWidth, 3);
      expect(wide.hopCount, 1);
    });

    test('a path round trips to the same string', () {
      final json = {
        'contacts': [contactJson(outPathList: 'a1b2,c3d4')],
      };

      final encoded = jsonDecode(StockConfig.parse(jsonEncode(json)).encode());

      expect((encoded['contacts'] as List).first['out_path_list'], 'a1b2,c3d4');
    });

    test('mixed hop widths are rejected rather than guessed at', () {
      final json = {
        'contacts': [contactJson(outPathList: 'a1b2,c3')],
      };

      expect(
        () => StockConfig.parse(jsonEncode(json)),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'contacts[0].out_path_list',
          ),
        ),
      );
    });

    test('a hop width beyond three bytes is rejected', () {
      final json = {
        'contacts': [contactJson(outPathList: 'a1b2c3d4')],
      };

      expect(
        () => StockConfig.parse(jsonEncode(json)),
        throwsA(isA<StockConfigFormatException>()),
      );
    });

    test('non-hex hop content is rejected', () {
      final json = {
        'contacts': [contactJson(outPathList: 'zzzz,c3d4')],
      };

      expect(
        () => StockConfig.parse(jsonEncode(json)),
        throwsA(isA<StockConfigFormatException>()),
      );
    });
  });

  group('malformed input', () {
    test('text that is not JSON is rejected', () {
      expect(
        () => StockConfig.parse('not json at all'),
        throwsA(isA<StockConfigFormatException>()),
      );
    });

    test('a top-level array is rejected', () {
      expect(
        () => StockConfig.parse('[]'),
        throwsA(isA<StockConfigFormatException>()),
      );
    });

    test('a public key of the wrong length is rejected', () {
      expect(
        () => StockConfig.parse('{"public_key":"aabb"}'),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'public_key',
          ),
        ),
      );
    });

    test('a numeric coordinate is rejected, since stock writes strings', () {
      expect(
        () => StockConfig.parse(
          '{"position_settings":{"latitude":39.5,"longitude":-84.6}}',
        ),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'position_settings.latitude',
          ),
        ),
      );
    });

    test('channels given as an object rather than an array is rejected', () {
      expect(
        () => StockConfig.parse('{"channels":{}}'),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'channels',
          ),
        ),
      );
    });

    test('the reported path points at the offending contact', () {
      final json = {
        'contacts': [contactJson(), contactJson(publicKey: 'aabb')],
      };

      expect(
        () => StockConfig.parse(jsonEncode(json)),
        throwsA(
          isA<StockConfigFormatException>().having(
            (e) => e.path,
            'path',
            'contacts[1].public_key',
          ),
        ),
      );
    });
  });
}
