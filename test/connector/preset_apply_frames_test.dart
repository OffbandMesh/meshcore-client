import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/services/radio_preset_service.dart';

/// What applying a preset puts on the wire to a companion or observer
/// (#730): stock CMD_SET_RADIO_PARAMS (11), CMD_SET_RADIO_TX_POWER (12) and,
/// when the preset carries one, CMD_SET_PATH_HASH_MODE (61).
void main() {
  late List<RadioPreset> presets;

  setUpAll(() {
    presets = mergeRadioPresets(
      parseUpstreamPresets(
        File('assets/radio_presets/meshcore-upstream.json').readAsStringSync(),
      ).presets,
      parseOverlayPresets(
        File('assets/radio_presets/offband.json').readAsStringSync(),
      ).presets,
    );
  });

  RadioPreset named(String title) =>
      presets.firstWhere((p) => p.title == title);

  List<int> le32(int v) => [
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];

  test('radio params: frequency in kHz, bandwidth in Hz, as stock expects', () {
    final philly = named('USA - Philly Mesh');
    // The form sends MHz * 1000, i.e. kHz; stock stores freq / 1000.0 as MHz.
    final frame = buildSetRadioParamsFrame(
      philly.frequencyKHz,
      philly.bandwidth.hz,
      philly.spreadingFactor.value,
      philly.codingRate.value,
    );
    expect(frame, [cmdSetRadioParams, ...le32(919500), ...le32(500000), 10, 5]);
    // Inside stock's accepted ranges (150000-2500000 kHz, BW <= 500000 Hz).
    expect(philly.frequencyKHz, inInclusiveRange(150000, 2500000));
    expect(philly.bandwidth.hz, lessThanOrEqualTo(500000));
  });

  test('path hash: published bytes become the zero-based mode on the wire', () {
    expect(
      buildSetPathHashModeFrame(named('USA - Philly Mesh').pathHashMode!),
      [cmdSetPathHashMode, 0, 1],
    );
    expect(
      buildSetPathHashModeFrame(
        named('USA - Southern California').pathHashMode!,
      ),
      [cmdSetPathHashMode, 0, 2],
    );
    expect(
      buildSetPathHashModeFrame(named('New Zealand (Gisborne)').pathHashMode!),
      [cmdSetPathHashMode, 0, 0],
    );
  });

  test('a preset without path hash or TX power sends neither', () {
    final usa = named('USA');
    expect(usa.pathHashMode, isNull);
    expect(usa.txPowerDbm, isNull);
  });
}
