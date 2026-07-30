// Self-telemetry GPS read (#110). The client refreshes the radio's own
// position via the self telemetry request (CMD_SEND_TELEMETRY_REQ, len==4)
// instead of APP_START (which reset the session), then extracts GPS from the
// CayenneLPP reply (firmware self-reply: [0x8B][reserved][self-pubkey 6][LPP]).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/helpers/cayenne_lpp.dart';

void main() {
  group('buildSendTelemetryReq(null), the self request', () {
    test(
      'is CMD_SEND_TELEMETRY_REQ + 3 reserved = 4-byte frame (firmware len==4)',
      () {
        // Firmware MyMesh.cpp:2030 matches the self request on `len == 4` (total
        // frame). 5 bytes ([39,0,0,0,0]) misses it and gets RESP_CODE_ERR (#110).
        expect(buildSendTelemetryReq(null), [cmdSendTelemetryReq, 0, 0, 0]);
      },
    );
  });

  group('CayenneLpp.extractGps', () {
    test('returns lat/lon from a parsed GPS reading', () {
      final parsed = <Map<String, dynamic>>[
        <String, dynamic>{
          'channel': 1,
          'values': <String, dynamic>{
            'voltage': 4.1,
            'gps': <String, dynamic>{
              'latitude': 12.34,
              'longitude': 56.78,
              'altitude': 100.0,
            },
          },
        },
      ];
      final gps = CayenneLpp.extractGps(parsed);
      expect(gps, isNotNull);
      expect(gps!.latitude, closeTo(12.34, 1e-9));
      expect(gps.longitude, closeTo(56.78, 1e-9));
    });

    test('returns null when no channel carries GPS', () {
      final parsed = <Map<String, dynamic>>[
        <String, dynamic>{
          'channel': 1,
          'values': <String, dynamic>{'voltage': 4.1},
        },
      ];
      expect(CayenneLpp.extractGps(parsed), isNull);
    });

    test('returns null for empty telemetry', () {
      expect(CayenneLpp.extractGps(<Map<String, dynamic>>[]), isNull);
    });
  });

  group('parseDeviceInfoStrings', () {
    test('extracts build date, model, and firmware version', () {
      final frame = Uint8List.fromList([
        0x0d, 0x0e, 0xaf, 0x28, 0, 0, 0, 0, // header (code, ver, counts, rsvd)
        ...'24-Jun-2026'.codeUnits, 0,
        ...'RAK 3401'.codeUnits, 0,
        ...'1.1.0-1.1.0'.codeUnits, 0,
      ]);
      expect(parseDeviceInfoStrings(frame), [
        '24-Jun-2026',
        'RAK 3401',
        '1.1.0-1.1.0',
      ]);
    });

    test('returns empty for a short frame', () {
      expect(parseDeviceInfoStrings(Uint8List.fromList([0x0d, 0x0e])), isEmpty);
    });
  });
}
