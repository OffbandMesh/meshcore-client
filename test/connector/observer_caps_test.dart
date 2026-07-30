// byte-82 offset + short-frame robustness for the device-info offband_caps
// read (#64 N1, Gemini MAJOR #4).
//
// The offset itself is verified against firmware source (MyMesh.cpp writes
// client_repeat@80, path_hash_mode@81, offband_caps@82 as consecutive
// out_frame[i++]; bytes 80/81 are shipping). These tests pin the bounds guard
// so a truncated or hostile short device-info frame can never index OOB, and
// that byte 82 is read verbatim when present. A live observer node confirms
// end-to-end at G2.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';

void main() {
  // A device-info frame of [len] bytes, byte 82 = [caps] when the frame is long
  // enough to carry it.
  Uint8List frame(int len, {int caps = 0}) {
    final f = Uint8List(len);
    if (len > 82) f[82] = caps;
    return f;
  }

  group('parseOffbandCaps, offset 82 + short-frame robustness', () {
    test('pre-v14 frame without the caps byte (len 82) -> null', () {
      expect(MeshCoreConnector.parseOffbandCaps(frame(82)), isNull);
    });

    test('len 83 reads byte 82 verbatim', () {
      expect(MeshCoreConnector.parseOffbandCaps(frame(83, caps: 0x01)), 0x01);
      expect(MeshCoreConnector.parseOffbandCaps(frame(83, caps: 0x00)), 0x00);
      expect(MeshCoreConnector.parseOffbandCaps(frame(90, caps: 0xFF)), 0xFF);
    });

    test('observer capability bit round-trips through supportsConfig', () {
      final caps = MeshCoreConnector.parseOffbandCaps(
        frame(83, caps: ObserverConfigClient.capWifiObserver),
      )!;
      expect(
        ObserverConfigClient.supportsConfig(
          firmwareVerCode: ObserverConfigClient.minVerCode,
          offbandCaps: caps,
        ),
        isTrue,
      );
    });

    test('hostile/truncated short frames never throw, always null', () {
      for (final n in [0, 1, 4, 80, 81, 82]) {
        expect(
          MeshCoreConnector.parseOffbandCaps(frame(n)),
          isNull,
          reason: 'frame length $n must not index byte 82',
        );
      }
    });
  });
}
