import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

/// Channel posts carry a claimed NAME and no key (#468), so adding a channel
/// sender to contacts hangs entirely on resolving that name against what the
/// radio has already heard. These pin the resolution rules, including the
/// namesake case the UI must never resolve on the user's behalf.
Contact _contact(String name, int keyByte, {int type = advTypeChat}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, keyByte)),
  name: name,
  type: type,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 8, 11),
);

void main() {
  late MeshCoreConnector connector;

  setUp(() {
    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
    connector.discoveredContactsForTest.clear();
  });

  group('resolveContactsByName', () {
    test(
      'matches a known contact ignoring case and surrounding whitespace',
      () {
        connector.contactsForTest.add(_contact('Ben', 0x11));

        expect(connector.resolveContactsByName('  bEn ').single.name, 'Ben');
      },
    );

    test('matches a discovered node that is not a contact yet', () {
      connector.discoveredContactsForTest.add(_contact('Rover', 0x22));

      final resolved = connector.resolveContactsByName('Rover');
      expect(
        resolved.single.publicKeyHex,
        _contact('Rover', 0x22).publicKeyHex,
      );
    });

    test('returns every node claiming the name, known ones first', () {
      connector.contactsForTest.add(_contact('Twin', 0x33));
      connector.discoveredContactsForTest.add(_contact('Twin', 0x44));

      final resolved = connector.resolveContactsByName('Twin');
      expect(resolved.length, 2);
      expect(resolved.first.publicKeyHex, _contact('x', 0x33).publicKeyHex);
    });

    test('a node in both lists resolves once, as the known contact', () {
      connector.contactsForTest.add(_contact('Dup', 0x55));
      connector.discoveredContactsForTest.add(_contact('Dup', 0x55));

      expect(connector.resolveContactsByName('Dup').length, 1);
    });

    test('a partial name is not a match', () {
      connector.contactsForTest.add(_contact('Benjamin', 0x66));

      expect(connector.resolveContactsByName('Ben'), isEmpty);
    });

    test('an unheard name resolves to nothing', () {
      expect(connector.resolveContactsByName('Ghost'), isEmpty);
    });

    test('an empty or whitespace-only name resolves to nothing', () {
      connector.contactsForTest.add(_contact('Ben', 0x77));

      expect(connector.resolveContactsByName(''), isEmpty);
      expect(connector.resolveContactsByName('   '), isEmpty);
    });
  });

  group('resolveContactKeysByName', () {
    test('returns the keys of the same nodes, in the same order', () {
      connector.contactsForTest.add(_contact('Twin', 0x33));
      connector.discoveredContactsForTest.add(_contact('Twin', 0x44));

      expect(
        connector.resolveContactKeysByName('Twin'),
        connector.resolveContactsByName('Twin').map((c) => c.publicKeyHex),
      );
    });

    test(
      'stays empty for an unheard name, so blocking falls back to the name',
      () {
        expect(connector.resolveContactKeysByName('Ghost'), isEmpty);
      },
    );
  });
}
