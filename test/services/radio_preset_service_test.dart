import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_preset.dart';
import 'package:meshcore_open/models/radio_settings.dart';
import 'package:meshcore_open/services/radio_preset_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String upstreamFile(List<Map<String, dynamic>> entries) => jsonEncode({
  'format': kUpstreamPresetFormat,
  'format_version': 1,
  'source': 'https://api.meshcore.nz/api/v1/config',
  'credit': 'Liam Cottle / MeshCore',
  'updated_at': '2026-10-01T00:00:00Z',
  'suggested_radio_settings': {'entries': entries},
});

String overlayFile(List<Map<String, dynamic>> presets) => jsonEncode({
  'format': kOverlayPresetFormat,
  'format_version': 1,
  'presets': presets,
});

Map<String, dynamic> up(String title, {String freq = '910.525'}) => {
  'title': title,
  'frequency': freq,
  'spreading_factor': '7',
  'bandwidth': '62.5',
  'coding_rate': '5',
};

Map<String, dynamic> ov(
  String id,
  String title, {
  double freq = 909.75,
  String region = 'USA',
}) => {
  'id': id,
  'title': title,
  'region': region,
  'frequency': freq,
  'bandwidth': 500,
  'spreading_factor': 10,
  'coding_rate': 5,
  'status': 'published',
};

RadioPreset preset(String title, String region, RadioPresetSource source) =>
    RadioPreset(
      id: '$source:$title',
      title: title,
      region: region,
      frequencyMHz: 910.525,
      bandwidth: LoRaBandwidth.bw62_5,
      spreadingFactor: LoRaSpreadingFactor.sf7,
      codingRate: LoRaCodingRate.cr4_5,
      source: source,
    );

void main() {
  late SharedPreferences prefs;
  final bundled = {
    '${kRadioPresetAssetDir}meshcore-upstream.json': upstreamFile([
      up('USA'),
      up('Canada'),
    ]),
    '${kRadioPresetAssetDir}offband.json': overlayFile([
      ov('oki', 'USA - OKI-Mesh 500kHz Test'),
    ]),
  };

  Future<String> loadBundled(String path) async {
    final text = bundled[path];
    if (text == null) throw StateError('no asset $path');
    return text;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  RadioPresetService service({
    Map<String, String>? remote,
    Object? remoteError,
    DateTime Function()? clock,
  }) => RadioPresetService(
    prefs: prefs,
    loadAsset: loadBundled,
    clock: clock,
    fetch: (url) async {
      if (remoteError != null) throw remoteError;
      final file = url.substring(kRadioPresetBaseUrl.length);
      final text = remote?[file];
      if (text == null) throw StateError('HTTP 404 for $url');
      return text;
    },
  );

  group('mergeRadioPresets (#728)', () {
    test('an overlay entry replaces the upstream one with the same title', () {
      final merged = mergeRadioPresets(
        [
          preset('USA', 'USA', RadioPresetSource.meshcore),
          preset('Canada', 'Canada', RadioPresetSource.meshcore),
        ],
        [preset('usa', 'USA', RadioPresetSource.offband)],
      );
      expect(merged.length, 2);
      final usa = merged.firstWhere((p) => p.title.toLowerCase() == 'usa');
      expect(usa.source, RadioPresetSource.offband);
    });

    test('sorts by region, then title', () {
      final merged = mergeRadioPresets(
        [
          preset('USA', 'USA', RadioPresetSource.meshcore),
          preset('Australia', 'Australia', RadioPresetSource.meshcore),
        ],
        [preset('USA - Arizona', 'USA', RadioPresetSource.offband)],
      );
      expect(merged.map((p) => p.title), ['Australia', 'USA', 'USA - Arizona']);
    });
  });

  group('RadioPresetService (#728)', () {
    test('offline: loads the bundled copies when nothing is saved', () async {
      final s = service();
      await s.load();
      expect(s.presets.map((p) => p.title), [
        'Canada',
        'USA',
        'USA - OKI-Mesh 500kHz Test',
      ]);
      expect(s.refreshError, isNull);
      expect(s.lastRefreshed, isNull);
    });

    test('refresh replaces the list, saves it, and records the time', () async {
      final now = DateTime.utc(2026, 10, 1, 12);
      final s = service(
        clock: () => now,
        remote: {
          kUpstreamPresetFile: upstreamFile([up('USA'), up('Brazil')]),
          kOverlayPresetFile: overlayFile([
            ov('philly', 'USA - Philly Mesh', freq: 919.5),
          ]),
        },
      );
      await s.load();
      expect(await s.refresh(), isTrue);
      expect(s.presets.map((p) => p.title), [
        'Brazil',
        'USA',
        'USA - Philly Mesh',
      ]);
      expect(s.refreshError, isNull);
      expect(s.lastRefreshed, now);

      // The saved copy is what the next launch starts from, even offline.
      final next = service(remoteError: StateError('offline'));
      await next.load();
      expect(next.presets.map((p) => p.title), contains('USA - Philly Mesh'));
      expect(next.lastRefreshed, now);
    });

    test('an overlay edit reaches the app with no new build', () async {
      final s = service(
        remote: {
          kUpstreamPresetFile: upstreamFile([up('USA')]),
          kOverlayPresetFile: overlayFile([
            ov('oki', 'USA - OKI-Mesh 500kHz Test', freq: 911.5),
          ]),
        },
      );
      await s.load();
      expect(
        s.presets.firstWhere((p) => p.id == 'offband:oki').frequencyMHz,
        909.75,
      );
      await s.refresh();
      expect(
        s.presets.firstWhere((p) => p.id == 'offband:oki').frequencyMHz,
        911.5,
      );
    });

    test('a failed refresh keeps the list in use and reports why', () async {
      final s = service(remoteError: StateError('network down'));
      await s.load();
      final before = s.presets.map((p) => p.title).toList();
      expect(await s.refresh(), isFalse);
      expect(s.presets.map((p) => p.title), before);
      expect(s.refreshError, contains('network down'));
      expect(s.lastRefreshed, isNull);
      expect(prefs.getKeys(), isEmpty);
    });

    test('a bad or empty file never replaces a good copy', () async {
      final s = service(
        remote: {
          kUpstreamPresetFile: '<html>502 Bad Gateway</html>',
          kOverlayPresetFile: overlayFile([]),
        },
      );
      await s.load();
      expect(await s.refresh(), isFalse);
      expect(s.presets.length, 3);
      expect(s.refreshError, contains(kUpstreamPresetFile));
      expect(s.refreshError, contains(kOverlayPresetFile));
    });

    test('one good file is still taken when the other fails', () async {
      final s = service(
        remote: {
          kOverlayPresetFile: overlayFile([ov('az', 'USA - Arizona')]),
        },
      );
      await s.load();
      expect(await s.refresh(), isFalse);
      expect(s.presets.map((p) => p.title), ['Canada', 'USA', 'USA - Arizona']);
      expect(s.refreshError, contains(kUpstreamPresetFile));
    });

    test('malformed entries are skipped and counted', () async {
      final s = service(
        remote: {
          kUpstreamPresetFile: upstreamFile([
            up('USA'),
            {'title': 'Broken'},
          ]),
          kOverlayPresetFile: overlayFile([ov('az', 'USA - Arizona')]),
        },
      );
      await s.load();
      await s.refresh();
      expect(s.skipped, 1);
      expect(s.presets.map((p) => p.title), isNot(contains('Broken')));
    });

    test(
      'refreshIfStale only refreshes an old or never-refreshed copy',
      () async {
        var now = DateTime.utc(2026, 10, 1, 12);
        var fetches = 0;
        final s = RadioPresetService(
          prefs: prefs,
          loadAsset: loadBundled,
          clock: () => now,
          fetch: (url) async {
            fetches++;
            return url.endsWith(kUpstreamPresetFile)
                ? upstreamFile([up('USA')])
                : overlayFile([ov('az', 'USA - Arizona')]);
          },
        );
        await s.load();
        await s.refreshIfStale();
        expect(fetches, 2);
        now = now.add(const Duration(hours: 1));
        await s.refreshIfStale();
        expect(fetches, 2);
        now = now.add(const Duration(hours: 12));
        await s.refreshIfStale();
        expect(fetches, 4);
      },
    );
  });

  group('bundled preset files (#728)', () {
    test('parse cleanly and do not clash on titles', () {
      final upstream = parseUpstreamPresets(
        File('assets/radio_presets/meshcore-upstream.json').readAsStringSync(),
      );
      final overlay = parseOverlayPresets(
        File('assets/radio_presets/offband.json').readAsStringSync(),
      );
      expect(upstream.skipped, 0);
      expect(overlay.skipped, 0);
      expect(upstream.presets.length, 26);
      expect(overlay.presets.length, 33);
      final merged = mergeRadioPresets(upstream.presets, overlay.presets);
      expect(merged.length, 59);
      final philly = merged.firstWhere((p) => p.title == 'USA - Philly Mesh');
      expect(philly.frequencyKHz, 919500);
      expect(philly.bandwidth, LoRaBandwidth.bw500);
      expect(philly.pathHashMode, 1);
      final euNarrow = merged.firstWhere((p) => p.title == 'EU/UK (Narrow)');
      expect(euNarrow.codingRate, LoRaCodingRate.cr4_8);
    });
  });
}
