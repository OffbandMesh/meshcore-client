// #1100: BLE pairing pin. The companion radio persists a pin set over
// CMD_SET_DEVICE_PIN (37) and reports the configured value in device info
// bytes 4..7 LE (companion_radio MyMesh.cpp). These tests pin the frame
// format, the parse, and the connector's validation.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('buildSetDevicePinFrame', () {
    test('encodes [cmd 37][pin x4 LE]', () {
      expect(
        buildSetDevicePinFrame(123456),
        Uint8List.fromList([37, 0x40, 0xE2, 0x01, 0x00]),
      );
    });

    test('0 clears to the firmware default', () {
      expect(buildSetDevicePinFrame(0), Uint8List.fromList([37, 0, 0, 0, 0]));
    });
  });

  group('parseDevicePin', () {
    Uint8List deviceInfo(int pin, {int length = 8}) {
      final frame = Uint8List(length);
      frame[0] = respCodeDeviceInfo;
      frame[1] = 14; // ver code
      frame[2] = 100; // MAX_CONTACTS / 2
      frame[3] = 40; // MAX_GROUP_CHANNELS
      if (length >= 8) {
        frame[4] = pin & 0xFF;
        frame[5] = (pin >> 8) & 0xFF;
        frame[6] = (pin >> 16) & 0xFF;
        frame[7] = (pin >> 24) & 0xFF;
      }
      return frame;
    }

    test('reads bytes 4..7 LE', () {
      expect(MeshCoreConnector.parseDevicePin(deviceInfo(654321)), 654321);
      expect(MeshCoreConnector.parseDevicePin(deviceInfo(0)), 0);
    });

    test('null on a frame too short to carry the field', () {
      expect(
        MeshCoreConnector.parseDevicePin(deviceInfo(0, length: 4)),
        isNull,
      );
    });
  });

  group('setDevicePin', () {
    late MeshCoreConnector c;
    late List<Uint8List> sent;

    setUp(() {
      c = MeshCoreConnector();
      sent = [];
      c.sendFrameOverrideForTest = sent.add;
      c.setConnectedForTest();
    });

    test('sends cmd 37 and updates the cached pin', () async {
      await c.setDevicePin(234567);
      expect(sent.single, buildSetDevicePinFrame(234567));
      expect(c.deviceBlePin, 234567);
    });

    test(
      'refuses an out-of-range pin without sending (firmware range)',
      () async {
        for (final bad in [1, 99999, 1000000, -1]) {
          await expectLater(
            () => c.setDevicePin(bad),
            throwsArgumentError,
            reason: '$bad is outside 0 / 100000-999999',
          );
        }
        expect(sent, isEmpty);
        expect(c.deviceBlePin, isNull);
      },
    );

    test('0 is a valid reset to the build default', () async {
      await c.setDevicePin(0);
      expect(sent.single, buildSetDevicePinFrame(0));
      expect(c.deviceBlePin, 0);
    });
  });
}
