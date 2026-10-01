import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/remote_radio_commands.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/models/radio_settings.dart';

RadioPreset preset(
  String id, {
  double mhz = 908.205,
  LoRaBandwidth bw = LoRaBandwidth.bw62_5,
  LoRaSpreadingFactor sf = LoRaSpreadingFactor.sf9,
  LoRaCodingRate cr = LoRaCodingRate.cr4_8,
  int? tx,
  int? hashBytes,
}) => RadioPreset(
  id: id,
  title: id,
  region: 'USA',
  frequencyMHz: mhz,
  bandwidth: bw,
  spreadingFactor: sf,
  codingRate: cr,
  source: RadioPresetSource.offband,
  txPowerDbm: tx,
  pathHashBytes: hashBytes,
);

void main() {
  group('matchRemotePresetId (#734)', () {
    final presets = [
      preset('arizona', tx: 20),
      preset(
        'oki',
        mhz: 909.75,
        bw: LoRaBandwidth.bw500,
        sf: LoRaSpreadingFactor.sf10,
        cr: LoRaCodingRate.cr4_5,
      ),
    ];

    test('matches the frequency a repeater reports, to the nearest kHz', () {
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '908.205017',
          bandwidthHz: 62500,
          spreadingFactor: 9,
          codingRate: 8,
        ),
        'arizona',
      );
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '909.750',
          bandwidthHz: 500000,
          spreadingFactor: 10,
          codingRate: 5,
        ),
        'oki',
      );
    });

    test('any differing value means custom (null)', () {
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '908.205',
          bandwidthHz: 62500,
          spreadingFactor: 9,
          codingRate: 5,
        ),
        isNull,
      );
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '908.300',
          bandwidthHz: 62500,
          spreadingFactor: 9,
          codingRate: 8,
        ),
        isNull,
      );
    });

    test('unknown or unparsable fields match nothing', () {
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '',
          bandwidthHz: 62500,
          spreadingFactor: 9,
          codingRate: 8,
        ),
        isNull,
      );
      expect(
        matchRemotePresetId(
          presets,
          frequencyText: '908.205',
          bandwidthHz: null,
          spreadingFactor: 9,
          codingRate: 8,
        ),
        isNull,
      );
    });
  });
}
