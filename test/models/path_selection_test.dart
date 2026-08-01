import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/path_selection.dart';

Contact _contact({
  required int pathLength,
  required int pathHashWidth,
  List<int> path = const [],
  int? pathOverride,
  List<int>? pathOverrideBytes,
}) {
  return Contact(
    publicKey: Uint8List(32),
    name: 'R',
    type: advTypeRepeater,
    pathLength: pathLength,
    pathHashWidth: pathHashWidth,
    path: Uint8List.fromList(path),
    pathOverride: pathOverride,
    pathOverrideBytes: pathOverrideBytes == null
        ? null
        : Uint8List.fromList(pathOverrideBytes),
    lastSeen: DateTime.utc(2026),
  );
}

void main() {
  const pathLenOffset = 35; // 1 cmd + 32 pubKey + 1 type + 1 flags

  group('resolvePathSelection width (#279)', () {
    test('device path reports true hops + the captured width', () {
      // Bandit 2026-08-01: a 6-hop 2-byte route (12 path bytes). It must NOT be
      // reported as 12 hops nor sent at width 1.
      final bytes = [
        0xC6, 0x5C, 0x64, 0x7A, 0x75, 0xC9, //
        0x73, 0x60, 0xF6, 0x9F, 0xFB, 0x97,
      ];
      final r = resolvePathSelection(
        _contact(pathLength: 6, pathHashWidth: 2, path: bytes),
      );
      expect(r.useFlood, isFalse);
      expect(r.hopCount, 6);
      expect(r.hashWidth, 2);
      expect(r.pathBytes.length, 12);
    });

    test('end to end: the device path encodes as 0x46, not 0x06', () {
      final bytes = [
        0xC6, 0x5C, 0x64, 0x7A, 0x75, 0xC9, //
        0x73, 0x60, 0xF6, 0x9F, 0xFB, 0x97,
      ];
      final r = resolvePathSelection(
        _contact(pathLength: 6, pathHashWidth: 2, path: bytes),
      );
      final frame = buildUpdateContactPathFrame(
        Uint8List(32),
        Uint8List.fromList(r.pathBytes),
        r.hopCount,
        hashWidth: r.hashWidth,
      );
      expect(frame[pathLenOffset], 0x46);
      expect(pathHopCount(frame[pathLenOffset]), 6);
      expect(pathHashSizeBytes(frame[pathLenOffset]), 2);
    });

    test('override: one 2-byte hop is 1 hop at width 2, not 2 hops', () {
      // The dialog stores pathOverride as a BYTE count (2); the selection must
      // still resolve to a single 2-byte hop.
      final r = resolvePathSelection(
        _contact(
          pathLength: 1,
          pathHashWidth: 2,
          pathOverride: 2,
          pathOverrideBytes: [0xC6, 0x5C],
        ),
      );
      expect(r.hopCount, 1);
      expect(r.hashWidth, 2);
    });

    test('legacy 1-byte net is unchanged', () {
      final r = resolvePathSelection(
        _contact(pathLength: 3, pathHashWidth: 1, path: [0xAA, 0xBB, 0xCC]),
      );
      expect(r.hopCount, 3);
      expect(r.hashWidth, 1);
    });

    test('flood override passes through as flood', () {
      final r = resolvePathSelection(
        _contact(pathLength: 0, pathHashWidth: 2, pathOverride: -1),
      );
      expect(r.useFlood, isTrue);
      expect(r.hopCount, -1);
    });

    test('path-history retry derives width from the contact', () {
      final retry = const PathSelection(
        pathBytes: [0xC6, 0x5C, 0xA1, 0xB2],
        hopCount: 99, // stale/ambiguous; must be recomputed
        useFlood: false,
      );
      final r = resolvePathSelection(
        _contact(
          pathLength: 2,
          pathHashWidth: 2,
          path: [0x00, 0x00, 0x00, 0x00],
        ),
        selection: retry,
      );
      expect(r.pathBytes.length, 4);
      expect(r.hopCount, 2);
      expect(r.hashWidth, 2);
    });
  });
}
