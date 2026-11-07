import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/device_population.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// #1065: FIRMWARE_VER_CODE is rolling back to 14 and no capability decision
/// may ride on it (owner ruling, Agent Mail 1401). Three shipped gates ANDed a
/// fork contract number on top of an already-correct caps-bit check, so they
/// went false on firmware that genuinely supports the feature.
///
/// The stock protection these floors appeared to provide is actually carried by
/// the population classifier, which nulls both caps bytes unless the device-info
/// frame's SHAPE corroborates the fork layout. The last group here proves that,
/// so removing the floors cannot leak a fork frame to a stock radio.
void main() {
  /// Stock replies are exactly 82 bytes. The fork appends caps byte 1 at 82,
  /// the FEM LNA state at 83 and caps byte 2 at 84.
  Uint8List deviceInfo({
    required int length,
    int verCode = 14,
    int caps1 = 0,
    int femByte = 0,
    int caps2 = 0,
  }) {
    final frame = Uint8List(length);
    if (length >= 1) frame[0] = respCodeDeviceInfo;
    if (length >= 2) frame[1] = verCode;
    if (length >= 83) frame[82] = caps1;
    if (length >= 84) frame[83] = femByte;
    if (length >= 85) frame[84] = caps2;
    return frame;
  }

  group('#1065 the three gates must not read FIRMWARE_VER_CODE', () {
    // The signatures take the caps byte and nothing else, so a version floor
    // cannot be reintroduced by accident: there is no parameter to read. These
    // assertions would have failed at ver 14 before the fix.
    test('block list is capable with its bit set', () {
      expect(firmwareSupportsOffbandBlock(offbandCapBlock), isTrue);
    });

    test('caplog is capable with its bit set', () {
      expect(firmwareSupportsOffbandCaplog(offbandCapCaplog), isTrue);
    });

    test('packet hash is capable with its bit set', () {
      expect(firmwareSupportsPktHash(offbandCap2PktHash), isTrue);
    });

    // A structural `isA<bool Function(int?)>()` assertion was tried here and
    // REMOVED: an optional positional `[int? firmwareVerCode]` still satisfies
    // that type, so the check passed while the floor was back in place. The
    // behavioural assertions above are the real guard -- they were verified to
    // fail against a deliberately reintroduced `>= 22` floor.
  });

  group('#1065 the bit is still the whole gate', () {
    test('a clear bit is false', () {
      expect(firmwareSupportsOffbandBlock(0x00), isFalse);
      expect(firmwareSupportsOffbandCaplog(0x00), isFalse);
      expect(firmwareSupportsPktHash(0x00), isFalse);
    });

    test('another feature bit does not open the gate', () {
      expect(firmwareSupportsOffbandBlock(offbandCapFemLna), isFalse);
      expect(firmwareSupportsOffbandCaplog(offbandCapBlock), isFalse);
      expect(firmwareSupportsPktHash(offbandCap2NotifyScope), isFalse);
    });

    test('absent caps bytes are false, never an error', () {
      expect(firmwareSupportsOffbandBlock(null), isFalse);
      expect(firmwareSupportsOffbandCaplog(null), isFalse);
      expect(firmwareSupportsPktHash(null), isFalse);
    });
  });

  group('#1065 the population classifier carries the stock protection', () {
    test('a stock-shape frame at ver 14 is stockModern, not offband', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfo(length: stockDeviceInfoLength, verCode: 14),
        firmwareVersion: 'v1.18.0-81dbae5',
      );
      expect(c.population, DevicePopulation.stockModern);
      expect(c.allowsOffbandFrames, isFalse);
    });

    test('a fork-shape frame at ver 14 is still offband', () {
      // The case the floors broke: the fork reporting the rolled-back code.
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfo(
          length: 85,
          verCode: 14,
          caps1: offbandCapBlock | offbandCapCaplog,
          caps2: offbandCap2PktHash,
        ),
        firmwareVersion: '1.4.0-1.17.0',
      );
      expect(c.population, DevicePopulation.offband);
      expect(c.allowsOffbandFrames, isTrue);
    });

    test('a stock radio yields no caps, so every gate is false', () {
      // What the connector does at meshcore_connector.dart:7924-7938: the caps
      // bytes are only parsed when the classifier allows fork frames.
      final frame = deviceInfo(length: stockDeviceInfoLength, verCode: 14);
      final c = classifyDevicePopulation(
        deviceInfo: frame,
        firmwareVersion: 'v1.18.0-81dbae5',
      );
      final caps1 = c.allowsOffbandFrames
          ? MeshCoreConnector.parseOffbandCaps(frame)
          : null;
      final caps2 = c.allowsOffbandFrames
          ? MeshCoreConnector.parseOffbandCaps2(frame)
          : null;

      expect(caps1, isNull);
      expect(caps2, isNull);
      expect(firmwareSupportsOffbandBlock(caps1), isFalse);
      expect(firmwareSupportsOffbandCaplog(caps1), isFalse);
      expect(firmwareSupportsPktHash(caps2), isFalse);
    });
  });
}
