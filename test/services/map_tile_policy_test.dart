import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshcore_open/services/map_tile_cache_service.dart';
import 'package:meshcore_open/widgets/osm_attribution.dart';

/// Records the headers each tile download is sent with, then fails it.
class _RecordingCacheManager implements BaseCacheManager {
  final List<Map<String, String>?> headersSeen = [];

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) {
    headersSeen.add(authHeaders);
    return Future.error(StateError('no network in tests'));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// OSMF tile policy (#1111): a distinct, stable User-Agent naming this app,
/// and visible "© OpenStreetMap contributors" on every map.
void main() {
  group('tile User-Agent', () {
    test('names this app, not upstream or a library default', () {
      const ua = MapTileCacheService.userAgent;
      expect(ua, contains('app.offband.meshcore'));
      expect(ua, isNot(contains('com.meshcore.open')));
      expect(ua, isNot(startsWith('flutter_map')));
    });

    test('every map tile request carries it', () {
      final service = MapTileCacheService(
        cacheManager: _RecordingCacheManager(),
      );
      expect(
        service.tileProvider.headers['User-Agent'],
        MapTileCacheService.userAgent,
      );
    });

    test('a TileLayer keeps it instead of putting in its own', () {
      final service = MapTileCacheService(
        cacheManager: _RecordingCacheManager(),
      );
      TileLayer(
        urlTemplate: kMapTileUrlTemplate,
        tileProvider: service.tileProvider,
      );
      expect(
        service.tileProvider.headers['User-Agent'],
        MapTileCacheService.userAgent,
      );
    });

    test('the area download sends it too', () async {
      final cache = _RecordingCacheManager();
      final service = MapTileCacheService(cacheManager: cache);
      await service.downloadRegion(
        bounds: LatLngBounds(const LatLng(0, 0), const LatLng(0.01, 0.01)),
        minZoom: 10,
        maxZoom: 10,
      );
      expect(cache.headersSeen, isNotEmpty);
      for (final headers in cache.headersSeen) {
        expect(headers?['User-Agent'], MapTileCacheService.userAgent);
      }
    });

    test('extra download headers add to it, never drop it', () async {
      final cache = _RecordingCacheManager();
      final service = MapTileCacheService(cacheManager: cache);
      await service.downloadRegion(
        bounds: LatLngBounds(const LatLng(0, 0), const LatLng(0.01, 0.01)),
        minZoom: 10,
        maxZoom: 10,
        headers: const {'X-Extra': '1'},
      );
      for (final headers in cache.headersSeen) {
        expect(headers?['User-Agent'], MapTileCacheService.userAgent);
        expect(headers?['X-Extra'], '1');
      }
    });
  });

  group('every map in lib/', () {
    final mapFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('TileLayer('))
        .toList();

    test('finds the six maps', () {
      expect(mapFiles.length, 6);
    });

    for (final file in mapFiles) {
      final source = file.readAsStringSync();
      final name = file.uri.pathSegments.last;

      test('$name shows the OSM credit', () {
        expect(source, contains('OsmAttribution('));
      });

      test('$name loads tiles through the shared provider', () {
        expect(source, contains('tileProvider: tileCache.tileProvider'));
        expect(source, isNot(contains('userAgentPackageName')));
      });
    }

    test('nothing in lib/ still names upstream\'s app', () {
      final offenders = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f.readAsStringSync().contains('com.meshcore.open'))
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty);
    });
  });

  testWidgets('the credit reads © OpenStreetMap contributors, uncovered', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [OsmAttribution()])),
      ),
    );
    expect(find.text(OsmAttribution.text).hitTestable(), findsOneWidget);
    expect(find.textContaining('©'), findsOneWidget);
  });
}
