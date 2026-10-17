import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/device_population.dart';

/// Builds a device-info reply frame of [length] bytes with [verCode] at
/// byte 1, mirroring RESP_CODE_DEVICE_INFO layouts:
/// stock ships exactly 82 bytes; the Offband fork appends offband_caps at
/// offset 82 (83 bytes) and caps byte 2 at offset 84 (85 bytes).
Uint8List deviceInfoFrame({required int length, required int verCode}) {
  final frame = Uint8List(length);
  if (length > 0) frame[0] = 13; // RESP_CODE_DEVICE_INFO
  if (length > 1) frame[1] = verCode;
  return frame;
}

void main() {
  group('classifyDevicePopulation', () {
    test('stock 1.17.x: 82-byte frame, ver 13', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 13),
        firmwareVersion: 'v1.17.0',
      );
      expect(c.population, DevicePopulation.stockLegacy);
      expect(c.allowsOffbandFrames, isFalse);
      expect(c.allowsCliFrame, isFalse);
    });

    test('stock 1.18.0: 82-byte frame, ver 14', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 14),
        firmwareVersion: 'v1.18.0',
      );
      expect(c.population, DevicePopulation.stockModern);
      expect(c.allowsOffbandFrames, isFalse);
      expect(c.allowsCliFrame, isTrue);
    });

    test('Offband ver 22: 83-byte frame (caps byte 1 only)', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 83, verCode: 22),
        firmwareVersion: '1.4.0-1.17.0',
      );
      expect(c.population, DevicePopulation.offband);
      expect(c.allowsOffbandFrames, isTrue);
      // No frame-66 CLI on the 1.17.0-base fork; flips only post-absorb.
      expect(c.allowsCliFrame, isFalse);
    });

    test('Offband ver 22: 85-byte frame (caps byte 2 present)', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 85, verCode: 22),
        firmwareVersion: '1.4.0-1.17.0',
      );
      expect(c.population, DevicePopulation.offband);
      expect(c.allowsOffbandFrames, isTrue);
    });

    test('Offband release image X-X version string (#691) still classifies', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 85, verCode: 22),
        firmwareVersion: '1.4.0-1.4.0',
      );
      expect(c.population, DevicePopulation.offband);
    });

    test('ver >= 14 with a LONG frame but stock version string is a conflict:'
        ' fails closed to stockLegacy', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 83, verCode: 14),
        firmwareVersion: 'v1.18.0',
      );
      expect(c.population, DevicePopulation.stockLegacy);
      expect(c.allowsOffbandFrames, isFalse);
      expect(c.allowsCliFrame, isFalse);
      expect(c.conflict, isTrue);
    });

    test('malformed short frame fails closed', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 3, verCode: 0),
        firmwareVersion: null,
      );
      expect(c.population, DevicePopulation.stockLegacy);
      expect(c.allowsOffbandFrames, isFalse);
      expect(c.allowsCliFrame, isFalse);
    });

    test('fork-shape frame with NO readable version fails closed'
        ' (uncorroborated shape never unlocks fork frames)', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 83, verCode: 22),
        firmwareVersion: null,
      );
      expect(c.population, DevicePopulation.stockLegacy);
      expect(c.conflict, isTrue);
      expect(c.allowsOffbandFrames, isFalse);
    });

    test('fork-shape frame with an unrecognizable version fails closed', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 83, verCode: 22),
        firmwareVersion: 'my-custom-build',
      );
      // 'my-custom-build' contains a dash, which the interim check reads as
      // the dual form; the #878 parser tightens this. What matters here is it
      // must not classify stock.
      expect(c.population, isNot(DevicePopulation.stockModern));
    });

    test('stock-shape frame with an Offband dual version string is a'
        ' conflict: fails closed', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 14),
        firmwareVersion: '1.4.0-1.17.0',
      );
      expect(c.population, DevicePopulation.stockLegacy);
      expect(c.conflict, isTrue);
      expect(c.allowsCliFrame, isFalse);
    });

    test('length 84 with a dual version string classifies offband', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 84, verCode: 22),
        firmwareVersion: '1.4.0-1.17.0',
      );
      expect(c.population, DevicePopulation.offband);
    });

    test('ver at maxKnownVerCode with stock shape and stock string stays'
        ' stockModern; one above fails closed', () {
      final at = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 32),
        firmwareVersion: 'v9.9.9',
      );
      expect(at.population, DevicePopulation.stockModern);
      final above = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 33),
        firmwareVersion: 'v9.9.9',
      );
      expect(above.population, DevicePopulation.stockLegacy);
    });

    test('stock ver wildly out of range fails closed', () {
      final c = classifyDevicePopulation(
        deviceInfo: deviceInfoFrame(length: 82, verCode: 255),
        firmwareVersion: 'v9.9.9',
      );
      expect(c.population, DevicePopulation.stockLegacy);
    });
  });
}
