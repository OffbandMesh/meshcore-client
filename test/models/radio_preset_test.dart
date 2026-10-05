import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/models/radio_settings.dart';

String upstream(List<Map<String, dynamic>> entries, {int version = 1}) =>
    jsonEncode({
      'format': kUpstreamPresetFormat,
      'format_version': version,
      'source': 'https://api.meshcore.nz/api/v1/config',
      'credit': 'Liam Cottle / MeshCore',
      'updated_at': '2026-10-01T00:00:00Z',
      'suggested_radio_settings': {'entries': entries},
    });

String overlay(List<Map<String, dynamic>> presets, {int version = 1}) =>
    jsonEncode({
      'format': kOverlayPresetFormat,
      'format_version': version,
      'presets': presets,
    });

Map<String, dynamic> overlayEntry(String id, {Map<String, dynamic>? extra}) => {
  'id': id,
  'title': 'USA - $id',
  'region': 'USA',
  'frequency': 909.75,
  'bandwidth': 500,
  'spreading_factor': 10,
  'coding_rate': 5,
  'status': 'published',
  ...?extra,
};

void main() {
  group('parseUpstreamPresets (#727)', () {
    test('reads the API shape, where numbers are strings', () {
      final r = parseUpstreamPresets(
        upstream([
          {
            'title': 'USA - Southern California',
            'description': '927.875MHz / SF7 / BW62.5 / CR5 / 3B',
            'frequency': '927.875',
            'spreading_factor': '7',
            'bandwidth': '62.5',
            'coding_rate': '5',
            'network_settings': {'path_hash_size': 3},
          },
          {
            'title': 'EU/UK (Narrow)',
            'frequency': '869.618',
            'spreading_factor': '8',
            'bandwidth': '62.5',
            'coding_rate': '8',
          },
        ]),
      );
      expect(r.skipped, 0);
      final socal = r.presets[0];
      expect(socal.id, 'meshcore:USA - Southern California');
      expect(socal.region, 'USA');
      expect(socal.frequencyKHz, 927875);
      expect(socal.bandwidth, LoRaBandwidth.bw62_5);
      expect(socal.spreadingFactor, LoRaSpreadingFactor.sf7);
      expect(socal.codingRate, LoRaCodingRate.cr4_5);
      expect(socal.pathHashBytes, 3);
      expect(socal.txPowerDbm, isNull);
      expect(socal.source, RadioPresetSource.meshcore);
      expect(r.presets[1].codingRate, LoRaCodingRate.cr4_8);
      expect(r.presets[1].pathHashBytes, isNull);
    });

    test('skips and counts malformed entries instead of failing', () {
      final r = parseUpstreamPresets(
        upstream([
          {
            'title': 'Good',
            'frequency': '910.525',
            'spreading_factor': '7',
            'bandwidth': '62.5',
            'coding_rate': '5',
          },
          {
            'title': 'Bad BW',
            'frequency': '910.525',
            'spreading_factor': '7',
            'bandwidth': '63',
            'coding_rate': '5',
          },
          {
            'title': 'Bad hash',
            'frequency': '910.525',
            'spreading_factor': '7',
            'bandwidth': '62.5',
            'coding_rate': '5',
            'network_settings': {'path_hash_size': 4},
          },
          {'title': 'Missing values'},
        ]),
      );
      expect(r.presets.map((p) => p.title), ['Good']);
      expect(r.skipped, 3);
    });

    test('rejects a wrong format or a newer format_version', () {
      expect(
        () => parseUpstreamPresets(overlay([])),
        throwsA(isA<RadioPresetFormatException>()),
      );
      expect(
        () => parseUpstreamPresets(upstream([], version: 2)),
        throwsA(isA<RadioPresetFormatException>()),
      );
      expect(
        () => parseUpstreamPresets('<html>502</html>'),
        throwsA(isA<RadioPresetFormatException>()),
      );
    });
  });

  group('parseOverlayPresets (#727)', () {
    test(
      'reads overlay entries with optional TX power, path hash, off-grid',
      () {
        final r = parseOverlayPresets(
          overlay([
            overlayEntry(
              'philly',
              extra: {'tx_power': 20, 'path_hash_size': 2},
            ),
            overlayEntry(
              'grid',
              extra: {
                'region': 'Off-Grid',
                'frequency': 918.0,
                'bandwidth': 250,
                'spreading_factor': 11,
                'coding_rate': 8,
                'off_grid': true,
              },
            ),
          ]),
        );
        expect(r.skipped, 0);
        final philly = r.presets[0];
        expect(philly.id, 'offband:philly');
        expect(philly.bandwidth, LoRaBandwidth.bw500);
        expect(philly.txPowerDbm, 20);
        expect(philly.pathHashBytes, 2);
        expect(philly.source, RadioPresetSource.offband);
        expect(philly.offGrid, isFalse);
        expect(r.presets[1].offGrid, isTrue);
        expect(r.presets[1].region, 'Off-Grid');
      },
    );

    test('drops retired entries without counting them as skipped', () {
      final r = parseOverlayPresets(
        overlay([
          overlayEntry('old', extra: {'status': 'retired'}),
          overlayEntry('new'),
        ]),
      );
      expect(r.presets.map((p) => p.id), ['offband:new']);
      expect(r.skipped, 0);
    });

    test('skips hand-edit mistakes: string numbers, bad TX, bad hash', () {
      final r = parseOverlayPresets(
        overlay([
          overlayEntry('a', extra: {'frequency': '909.75'}),
          overlayEntry('b', extra: {'tx_power': 40}),
          overlayEntry('c', extra: {'path_hash_size': '2'}),
          overlayEntry('d', extra: {'coding_rate': 4}),
        ]),
      );
      expect(r.presets, isEmpty);
      expect(r.skipped, 4);
    });
  });

  group('upstreamRegionFor (#727)', () {
    test('groups upstream titles by their leading region', () {
      expect(upstreamRegionFor('USA'), 'USA');
      expect(upstreamRegionFor('USA - Southern California'), 'USA');
      expect(upstreamRegionFor('Australia: QLD'), 'Australia');
      expect(upstreamRegionFor('Australia (Narrow)'), 'Australia');
      expect(upstreamRegionFor('EU/UK (Narrow)'), 'EU/UK');
      expect(upstreamRegionFor('Portugal 433'), 'Portugal');
      expect(upstreamRegionFor('Portugal 868'), 'Portugal');
      expect(upstreamRegionFor('Costa Rica'), 'Costa Rica');
      expect(upstreamRegionFor('New Zealand (Gisborne)'), 'New Zealand');
    });
  });

  group('presetPathHashMatches (#747)', () {
    final r = parseUpstreamPresets(
      upstream([
        {
          'title': 'Canada',
          'frequency': '910.525',
          'spreading_factor': '7',
          'bandwidth': '62.5',
          'coding_rate': '5',
          'network_settings': {'path_hash_size': 3},
        },
        {
          'title': 'USA',
          'frequency': '910.525',
          'spreading_factor': '7',
          'bandwidth': '62.5',
          'coding_rate': '5',
        },
      ]),
    );
    final canada = r.presets[0];
    final usa = r.presets[1];

    test('a preset with a path hash only fits a radio on that size', () {
      expect(presetPathHashMatches(canada, 3), isTrue);
      expect(presetPathHashMatches(canada, 2), isFalse);
      expect(presetPathHashMatches(canada, 1), isFalse);
    });

    test('a preset without one fits any radio', () {
      for (final bytes in [1, 2, 3]) {
        expect(presetPathHashMatches(usa, bytes), isTrue);
      }
    });

    test('a USA radio on 1- or 2-byte hashes is not mistaken for Canada', () {
      // Same radio values; Canada sorts first by region, so without the
      // path hash check it wins (the D1 screenshot).
      for (final bytes in [1, 2]) {
        final fitting = r.presets
            .where((p) => presetPathHashMatches(p, bytes))
            .map((p) => p.title);
        expect(fitting, ['USA']);
      }
    });
  });

  group('path hash bytes to firmware mode (#649)', () {
    test('published bytes map to the zero-based firmware mode', () {
      expect(pathHashModeForBytes(1), 0);
      expect(pathHashModeForBytes(2), 1);
      expect(pathHashModeForBytes(3), 2);
    });

    test('a published 2 never becomes mode 2 (3-byte hashes)', () {
      expect(pathHashModeForBytes(2), isNot(2));
    });

    test('absent or out-of-range sizes send nothing', () {
      expect(pathHashModeForBytes(null), isNull);
      expect(pathHashModeForBytes(0), isNull);
      expect(pathHashModeForBytes(4), isNull);
    });

    test('a parsed preset exposes its mode', () {
      final r = parseUpstreamPresets(
        upstream([
          {
            'title': 'Canada',
            'frequency': '910.525',
            'spreading_factor': '7',
            'bandwidth': '62.5',
            'coding_rate': '5',
            'network_settings': {'path_hash_size': 3},
          },
          {
            'title': 'USA',
            'frequency': '910.525',
            'spreading_factor': '7',
            'bandwidth': '62.5',
            'coding_rate': '5',
          },
        ]),
      );
      expect(r.presets[0].pathHashMode, 2);
      expect(r.presets[1].pathHashMode, isNull);
    });
  });
}
