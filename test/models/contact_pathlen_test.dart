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

    test('2-byte-mode 2-hop (0x42) keeps all FOUR bytes (#309)', () {
      // 0x42 = size 2, count 2 -> 2 hops occupying 2*2 = 4 bytes.
      //
      // Pre-#309 the low 6 bits were read as a byte count, so this kept only
      // the first 2 bytes and silently discarded the second hop. That is the
      // truncation behind #240's failed repeater logins.
      final c = Contact.fromFrame(
        _frame(pathLen: 0x42, pathBytes: [0xC6, 0x5C, 0xA1, 0xB2]),
      )!;
      expect(c.pathLength, 2); // HOPS, not bytes
      expect(c.pathHashWidth, 2);
      expect(c.path, [0xC6, 0x5C, 0xA1, 0xB2]); // all 4 bytes retained
    });

    test('2-byte-mode single hop (0x41) is 1 hop of 2 bytes (#309)', () {
      // Bandit's C65C case: ONE hop, previously surfaced as "2 hops".
      final c = Contact.fromFrame(
        _frame(pathLen: 0x41, pathBytes: [0xC6, 0x5C]),
      )!;
      expect(c.pathLength, 1);
      expect(c.pathHashWidth, 2);
      expect(c.path, [0xC6, 0x5C]);
    });

    test('3-byte-mode 2-hop (0x82) keeps six bytes (#309)', () {
      final c = Contact.fromFrame(
        _frame(pathLen: 0x82, pathBytes: [1, 2, 3, 4, 5, 6]),
      )!;
      expect(c.pathLength, 2);
      expect(c.pathHashWidth, 3);
      expect(c.path, [1, 2, 3, 4, 5, 6]);
    });

    test('flood sentinel (0xFF) stays -1, empty path', () {
      final c = Contact.fromFrame(_frame(pathLen: 0xFF))!;
      expect(c.pathLength, -1);
      expect(c.path, isEmpty);
    });
  });
}
