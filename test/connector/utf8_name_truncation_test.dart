// Grapheme-safe name truncation (#636).
//
// The on-wire name field is 32 bytes including a null terminator, so 31 are
// usable. Before this fix the three writers copied raw bytes up to that
// boundary, cutting multi-byte characters in half and putting invalid UTF-8 on
// the wire. ASCII names were unaffected, which is why it went unnoticed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// Decodes strictly. Throws if the bytes are not valid UTF-8, which is exactly
/// the failure this fix prevents.
String strictDecode(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: false);

void main() {
  group('utf8TruncateToBytes (#636)', () {
    test('leaves anything that already fits completely alone', () {
      for (final s in ['', 'Bob', 'Roger KY4RS', 'a' * 31]) {
        expect(utf8TruncateToBytes(s, 31), utf8.encode(s), reason: s);
      }
    });

    test('never emits invalid UTF-8, whatever the cut point', () {
      // The core property. Sweep every budget across a string whose characters
      // are 1, 3 and 4 bytes, so a byte-wise cut would land mid-character at
      // many of these lengths.
      const s = 'ab中文🧙cd漢字';
      for (var budget = 0; budget <= utf8.encode(s).length + 2; budget++) {
        final out = utf8TruncateToBytes(s, budget);
        expect(out.length, lessThanOrEqualTo(budget));
        // Would throw on a split character.
        expect(
          () => strictDecode(out),
          returnsNormally,
          reason: 'budget $budget',
        );
        expect(
          s.startsWith(strictDecode(out)),
          isTrue,
          reason: 'budget $budget',
        );
      }
    });

    test('CJK truncates on a character boundary, not a byte one', () {
      // 11 CJK characters is 33 bytes against a 31-byte budget.
      const name = '中文节点名称测试一二三';
      expect(utf8.encode(name).length, 33);
      final out = utf8TruncateToBytes(name, 31);
      // 10 characters at 3 bytes each fit; the 11th does not.
      expect(out.length, 30);
      expect(strictDecode(out), '中文节点名称测试一二');
    });

    test('a ZWJ emoji sequence is kept whole or dropped whole', () {
      // The mage is 4 codepoints joined by ZWJ plus a variation selector, 13
      // bytes. A codepoint-safe cut would still be wrong here: it could leave a
      // bare mage, a dangling joiner, or an orphaned selector.
      const mage = '\u{1F9D9}‍♂️';
      expect(utf8.encode(mage).length, 13);

      // One byte short of fitting: the whole cluster must go.
      expect(utf8TruncateToBytes(mage, 12), isEmpty);
      // Exactly fitting: kept intact.
      expect(strictDecode(utf8TruncateToBytes(mage, 13)), mage);

      // And no partial cluster survives at any budget below 13.
      for (var b = 0; b < 13; b++) {
        expect(utf8TruncateToBytes(mage, b), isEmpty, reason: 'budget $b');
      }
    });

    test('a zero or negative budget yields nothing', () {
      expect(utf8TruncateToBytes('anything', 0), isEmpty);
      expect(utf8TruncateToBytes('anything', -5), isEmpty);
    });
  });

  group('the three writers are grapheme-safe (#636)', () {
    // Reads a fixed-width, null-padded name field back out.
    String nameFrom(Uint8List frame, int offset, int width) {
      final slice = frame.sublist(offset, offset + width);
      final end = slice.indexOf(0);
      return strictDecode(slice.sublist(0, end < 0 ? slice.length : end));
    }

    const cjk = '中文节点名称测试一二三';

    test('buildSetAdvertNameFrame: own advert name survives intact', () {
      // The most externally visible of the three: this is the name the whole
      // mesh sees and the name embedded in emitted contact cards.
      final frame = buildSetAdvertNameFrame(cjk);
      final decoded = strictDecode(frame.sublist(1));
      expect(decoded, '中文节点名称测试一二');
      expect(frame.length - 1, lessThanOrEqualTo(maxNameSize - 1));
    });

    test('buildUpdateContactPathFrame: contact name survives intact', () {
      final frame = buildUpdateContactPathFrame(
        Uint8List(pubKeySize),
        Uint8List(0),
        -1,
        name: cjk,
      );
      expect(nameFrom(frame, contactNameOffset, maxNameSize), '中文节点名称测试一二');
    });

    test('buildSetChannelFrame: channel name survives intact', () {
      final frame = buildSetChannelFrame(0, cjk, Uint8List(16));
      // [cmd][idx][name x32][psk x16]
      expect(nameFrom(frame, 2, maxNameSize), '中文节点名称测试一二');
    });

    test('ASCII names are byte-identical to the old behaviour', () {
      // No regression for the overwhelmingly common case.
      final frame = buildSetAdvertNameFrame('Roger KY4RS');
      expect(strictDecode(frame.sublist(1)), 'Roger KY4RS');
    });
  });
}
