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
      expect(
        PathHelper.formatPathHex([0x84, 0xab, 0x12, 0x34], 2),
        '84AB,1234',
      );
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

  group('PathHelper trace-width helpers (#150)', () {
    test(
      'tracePathSz = floor(log2(width)); 3 falls back to the 2-byte hop',
      () {
        expect(PathHelper.tracePathSz(1), 0);
        expect(PathHelper.tracePathSz(2), 1);
        expect(PathHelper.tracePathSz(3), 1); // largest power of two <= 3 is 2
        expect(PathHelper.tracePathSz(4), 2);
        expect(PathHelper.tracePathSz(0), 0); // clamped to 1
      },
    );

    test('traceHopBytes = 1 << tracePathSz', () {
      expect(PathHelper.traceHopBytes(1), 1);
      expect(PathHelper.traceHopBytes(2), 2);
      expect(PathHelper.traceHopBytes(3), 2);
      expect(PathHelper.traceHopBytes(4), 4);
    });

    test('packPrefix packs the leading width bytes big-endian', () {
      expect(PathHelper.packPrefix([0x6a, 0xab, 0x12], 0, 1), 0x6a);
      expect(PathHelper.packPrefix([0x6a, 0xab, 0x12], 0, 2), 0x6aab);
      expect(PathHelper.packPrefix([0x00, 0x6a, 0xab], 1, 2), 0x6aab);
    });

    test('tracePathHops groups packed hops (width 1 == per-byte)', () {
      expect(PathHelper.tracePathHops([0x6a, 0xab, 0x12], 1), [
        0x6a,
        0xab,
        0x12,
      ]);
      expect(PathHelper.tracePathHops([0x6a, 0xab, 0xc1, 0xd2], 2), [
        0x6aab,
        0xc1d2,
      ]);
    });

    test('buildTraceRoundTrip — repeater width 1: out + target + reverse', () {
      expect(
        PathHelper.buildTraceRoundTrip(
          routingPath: [0x0a, 0x0b],
          routingWidth: 1,
          hopBytes: 1,
          throughTarget: true,
          targetPrefix: [0xcc],
        ),
        [0x0a, 0x0b, 0xcc, 0x0b, 0x0a],
      );
    });

    test('buildTraceRoundTrip — repeater width 2 mirrors by hop, not byte', () {
      expect(
        PathHelper.buildTraceRoundTrip(
          routingPath: [0xa1, 0xa2, 0xb1, 0xb2],
          routingWidth: 2,
          hopBytes: 2,
          throughTarget: true,
          targetPrefix: [0x71, 0x72],
        ),
        [0xa1, 0xa2, 0xb1, 0xb2, 0x71, 0x72, 0xb1, 0xb2, 0xa1, 0xa2],
      );
    });

    test('buildTraceRoundTrip — chat: far hop is the turnaround', () {
      expect(
        PathHelper.buildTraceRoundTrip(
          routingPath: [0x0a, 0x0b],
          routingWidth: 1,
          hopBytes: 1,
          throughTarget: false,
          targetPrefix: const [],
        ),
        [0x0a, 0x0b, 0x0a],
      );
    });
  });
}
