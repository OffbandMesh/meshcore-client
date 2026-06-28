import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/path_helper.dart';
import 'package:meshcore_open/models/contact.dart';

Contact _contact({
  required List<int> prefix,
  required String name,
  required int type,
}) {
  final key = Uint8List(32);
  for (var i = 0; i < prefix.length; i++) {
    key[i] = prefix[i];
  }
  return Contact(
    publicKey: key,
    name: name,
    type: type,
    pathLength: 0,
    path: Uint8List(0),
    lastSeen: DateTime.now(),
  );
}

void main() {
  group('PathHelper.formatPathHex (#154)', () {
    test('width 1 — one hop per byte, comma-separated', () {
      expect(PathHelper.formatPathHex([0x84, 0xab, 0x12], 1), '84,AB,12');
    });

    test('width 2 — groups two bytes per hop', () {
      expect(PathHelper.formatPathHex([0x84, 0xab, 0x12, 0x34], 2), '84AB,1234');
    });

    test('width 3 — groups three bytes per hop', () {
      expect(
        PathHelper.formatPathHex([0x01, 0x02, 0x03, 0x04, 0x05, 0x06], 3),
        '010203,040506',
      );
    });

    test('trailing partial hop is kept, not dropped', () {
      expect(PathHelper.formatPathHex([0x84, 0xab, 0x12], 2), '84AB,12');
    });

    test('empty path → empty string', () {
      expect(PathHelper.formatPathHex([], 2), '');
    });
  });

  group('PathHelper.resolvePathNames (#154)', () {
    test('width 1 — resolves per-byte, ignoring chat nodes', () {
      final contacts = [
        _contact(prefix: [0xF2], name: 'MunTui', type: advTypeChat),
        _contact(prefix: [0x7E], name: 'zrepeater', type: advTypeRepeater),
        _contact(prefix: [0xBA], name: 'USS Ronald Reagan', type: advTypeRoom),
      ];
      final resolved = PathHelper.resolvePathNames(
        [0xF2, 0x7E, 0xBA],
        contacts,
        1,
      );
      expect(resolved, equals('F2 → zrepeater → USS Ronald Reagan'));
    });

    test('width 2 — resolves by the full 2-byte hop prefix', () {
      final contacts = [
        _contact(
          prefix: [0x7E, 0xAB],
          name: 'zrepeater',
          type: advTypeRepeater,
        ),
        // Shares the first byte but differs in the second — must NOT match.
        _contact(prefix: [0x7E, 0x01], name: 'decoy', type: advTypeRepeater),
      ];
      final resolved = PathHelper.resolvePathNames([0x7E, 0xAB], contacts, 2);
      expect(resolved, equals('zrepeater'));
    });
  });
}
