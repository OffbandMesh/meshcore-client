import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// The client-id length in CMD_APP_START is load-bearing (#297).
///
/// Stock firmware treats `cmd_frame[1..7]` as reserved and reads the app name at
/// a FIXED offset 8. Wadamesh reads byte 1 as the client-id length and the app
/// name at `2 + cid_len`. Only `cid_len == 6` satisfies both. If this test ever
/// fails, one of the two firmwares is now reading the app name out of the
/// client-id bytes.
void main() {
  group('buildAppStartFrame', () {
    test('declares a 6-byte client id so the app name lands at offset 8', () {
      final clientId = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final frame = buildAppStartFrame(appName: 'Offband', clientId: clientId);

      expect(frame[0], cmdAppStart);
      expect(frame[1], 6, reason: 'cid_len must be 6 for both firmwares');
      expect(frame.sublist(2, 8), clientId);
      expect(
        String.fromCharCodes(frame.sublist(8, 8 + 'Offband'.length)),
        'Offband',
        reason: 'app name must start at offset 8',
      );
    });

    test('zero-pads a short client id without moving the app name', () {
      final frame = buildAppStartFrame(
        appName: 'X',
        clientId: Uint8List.fromList([0xAA, 0xBB]),
      );

      expect(frame[1], 6);
      expect(frame.sublist(2, 8), [0xAA, 0xBB, 0, 0, 0, 0]);
      expect(String.fromCharCodes(frame.sublist(8, 9)), 'X');
    });

    test('truncates an over-long client id without moving the app name', () {
      final frame = buildAppStartFrame(
        appName: 'X',
        clientId: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      );

      expect(frame[1], 6);
      expect(frame.sublist(2, 8), [1, 2, 3, 4, 5, 6]);
      expect(String.fromCharCodes(frame.sublist(8, 9)), 'X');
    });

    test('omitted client id still keeps the frame shape', () {
      final frame = buildAppStartFrame(appName: 'X');

      expect(frame[1], 6);
      expect(frame.sublist(2, 8), [0, 0, 0, 0, 0, 0]);
      expect(String.fromCharCodes(frame.sublist(8, 9)), 'X');
    });
  });
}
