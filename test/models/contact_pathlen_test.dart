import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';

/// Builds a minimal RESP_CODE_CONTACT frame with a caller-chosen path-len byte.
Uint8List _frame({required int pathLen, List<int> pathBytes = const []}) {
  final frame = Uint8List(contactFrameSize);
  frame[0] = respCodeContact;
  for (var i = contactPubKeyOffset; i < contactPubKeyOffset + pubKeySize; i++) {
    frame[i] = 0x11; // non-zero public key passes the zeroed-key guard
  }
  frame[contactTypeOffset] = advTypeRepeater;
  frame[contactFlagsOffset] = 0;
  frame[contactPathLenOffset] = pathLen;
  for (var i = 0; i < pathBytes.length && i < maxPathSize; i++) {
    frame[contactPathOffset + i] = pathBytes[i];
  }
  const name = 'TestNode';
  for (var i = 0; i < name.length; i++) {
    frame[contactNameOffset + i] = name.codeUnitAt(i);
  }
  return frame;
}

void main() {
  group('Contact.fromFrame path-len decode (#222)', () {
    test('direct at 2-byte mode (0x40) -> 0 hops, empty path', () {
      final c = Contact.fromFrame(_frame(pathLen: 0x40))!;
      expect(c.pathLength, 0); // was 64 pre-#222
      expect(c.path, isEmpty); // was 64 junk bytes pre-#222
    });

    test('plain direct (0x00) -> 0 hops, empty path', () {
      final c = Contact.fromFrame(_frame(pathLen: 0x00))!;
      expect(c.pathLength, 0);
      expect(c.path, isEmpty);
    });

    test('1-byte-mode 3-byte path keeps its length and bytes', () {
      final c = Contact.fromFrame(
        _frame(pathLen: 0x03, pathBytes: [0xAA, 0xBB, 0xCC]),
      )!;
      expect(c.pathLength, 3);
      expect(c.path, [0xAA, 0xBB, 0xCC]);
    });

    test('2-byte-mode multi-hop (0x44) decodes to 4 bytes, not flood', () {
      // High bits = mode-1 hint, low bits = 4 bytes = a 2-hop path at 2-byte
      // width. Pre-#222 the raw 68 (> maxPathSize) was mis-flagged as flood.
      final c = Contact.fromFrame(
        _frame(pathLen: 0x44, pathBytes: [1, 2, 3, 4]),
      )!;
      expect(c.pathLength, 4);
      expect(c.path, [1, 2, 3, 4]);
      expect(
        realHopCount(c.pathLength, 2),
        2,
      ); // 4 bytes / 2-byte width = 2 hops
    });

    test('flood sentinel (0xFF) stays -1, empty path', () {
      final c = Contact.fromFrame(_frame(pathLen: 0xFF))!;
      expect(c.pathLength, -1);
      expect(c.path, isEmpty);
    });
  });
}
