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
  group('remote radio commands (#662)', () {
    test('set radio keeps its existing format', () {
      expect(
        setRadioCommand('908.205', 62500, 9, 8),
        'set radio 908.205,62.5,9,8',
      );
    });

    test('tempradio carries the values of the OKI-published command', () {
      // docs.okimesh.org 500kHz-testing: tempradio 909.750,500,10,5,1440.
      // "500.0" and "500" parse to the same bandwidth (firmware strtof,
      // CommonCLI.cpp tempradio handler).
      expect(
        tempRadioCommand('909.750', 500000, 10, 5, kTempRadioDefaultMinutes),
        'tempradio 909.750,500.0,10,5,1440',
      );
    });

    test('coding rate goes out as the 4/x denominator', () {
      expect(tempRadioCommand('910.525', 62500, 7, 5, 60), endsWith(',7,5,60'));
    });

    test('duration must be 1 to the firmware overflow bound', () {
      expect(parseTempRadioMinutes('1440'), 1440);
      expect(parseTempRadioMinutes(' 1 '), 1);
      expect(parseTempRadioMinutes('$kTempRadioMaxMinutes'), 35791);
      expect(parseTempRadioMinutes('${kTempRadioMaxMinutes + 1}'), isNull);
      expect(parseTempRadioMinutes('0'), isNull);
      expect(parseTempRadioMinutes('-5'), isNull);
      expect(parseTempRadioMinutes('1.5'), isNull);
      expect(parseTempRadioMinutes(''), isNull);
      // 2000 + 35791 min fits a 32-bit int; one more minute does not.
      expect(2000 + kTempRadioMaxMinutes * 60 * 1000, lessThan(1 << 31));
      expect(
        2000 + (kTempRadioMaxMinutes + 1) * 60 * 1000,
        greaterThan(1 << 31),
      );
    });

    test('tempradio is sent after every other command', () {
      final ordered = withRetuneLast([
        'set name X',
        'tempradio 909.75,500.0,10,5,1440',
        'set tx 20',
        'set repeat on',
      ], isRetuneCommand);
      expect(ordered, [
        'set name X',
        'set tx 20',
        'set repeat on',
        'tempradio 909.75,500.0,10,5,1440',
      ]);
    });

    test('without tempradio the order is unchanged', () {
      final commands = [
        'set name X',
        'set radio 908.205,62.5,9,8',
        'set tx 20',
      ];
      expect(withRetuneLast(commands, isRetuneCommand), commands);
    });
  });

  group('preset path hash on remote nodes (#735)', () {
    test('published bytes become the zero-based CLI mode', () {
      final philly = preset('philly', hashBytes: 2);
      final socal = preset('socal', hashBytes: 3);
      expect(
        setPathHashModeCommand(philly.pathHashMode!),
        'set path.hash.mode 1',
      );
      expect(
        setPathHashModeCommand(socal.pathHashMode!),
        'set path.hash.mode 2',
      );
      expect(preset('usa').pathHashMode, isNull);
    });

    test('a preset path hash is held back from a temporary change', () {
      expect(
        sendsPresetPathHash(temporaryRadio: true, pathHashFromPreset: true),
        isFalse,
      );
      expect(
        sendsPresetPathHash(temporaryRadio: false, pathHashFromPreset: true),
        isTrue,
      );
    });

    test('a path hash set by hand is always sent', () {
      expect(
        sendsPresetPathHash(temporaryRadio: true, pathHashFromPreset: false),
        isTrue,
      );
      expect(
        sendsPresetPathHash(temporaryRadio: false, pathHashFromPreset: false),
        isTrue,
      );
    });
  });

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
