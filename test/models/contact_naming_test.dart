// Custom Name override for contacts (#750), model half.
//
// `Contact.name` becomes a getter returning `customName ?? receivedName`, so
// the 85 existing display reads stay correct and untouched while every write
// site is forced to say which name it means.
//
// Tests T1 to T8 and T31 from the plan of record,
// docs/initiatives/standalone/750-contact-naming/PLAN.md.
//
// The negatives here are the ones that matter. A positive-only suite would keep
// passing while an advert quietly took the user's chosen name back.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';

Contact _contact({required String receivedName, String? customName}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, 0x11)),
  receivedName: receivedName,
  customName: customName,
  type: 1,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

void main() {
  group('Contact.name resolution (#750)', () {
    test('T1 + returns the custom name when one is set', () {
      final c = _contact(receivedName: 'KQ4EZN-Repeater', customName: 'Chuck');

      expect(c.name, 'Chuck');
    });

    test('T2 - falls back to the received name, and does not invent one', () {
      final c = _contact(receivedName: 'KQ4EZN-Repeater');

      expect(c.name, 'KQ4EZN-Repeater');
      expect(c.customName, isNull);
    });

    test('T3 - an empty custom name counts as unset, not as a blank name', () {
      // Otherwise a user who clears the field by deleting its text gets a blank
      // display name with no way back.
      final c = _contact(receivedName: 'KQ4EZN-Repeater', customName: '');

      expect(c.name, 'KQ4EZN-Repeater');
    });

    test('T4 - a whitespace-only custom name counts as unset', () {
      final c = _contact(receivedName: 'KQ4EZN-Repeater', customName: '   ');

      expect(c.name, 'KQ4EZN-Repeater');
    });

    test(
      'T5 + copyWith(receivedName:) updates it and keeps the custom name',
      () {
        final c = _contact(
          receivedName: 'old-advert-name',
          customName: 'Chuck',
        ).copyWith(receivedName: 'new-advert-name');

        expect(c.receivedName, 'new-advert-name');
        expect(c.customName, 'Chuck');
      },
    );

    test('T6 - copyWith(receivedName:) does not change the displayed name', () {
      // This is the whole point of the epic: an advert updates what the node
      // calls itself and never disturbs what the user calls it.
      final c = _contact(
        receivedName: 'old-advert-name',
        customName: 'Chuck',
      ).copyWith(receivedName: 'new-advert-name');

      expect(c.name, 'Chuck');
    });

    test('T6b + clearing the custom name reveals the newest received name', () {
      final renamed = _contact(
        receivedName: 'old-advert-name',
        customName: 'Chuck',
      ).copyWith(receivedName: 'new-advert-name', clearCustomName: true);

      expect(renamed.customName, isNull);
      expect(renamed.name, 'new-advert-name');
    });

    test('T28 - a custom name keeps CJK, emoji and ZWJ sequences intact', () {
      // A custom name never crosses the wire, so #636's grapheme truncation
      // must not be applied to it.
      const rich = '测试 🧙‍♂️ Chuck';
      final c = _contact(receivedName: 'plain', customName: rich);

      expect(c.name, rich);
      expect(c.customName, rich);
    });
  });
}
