import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/corescope_service.dart';

void main() {
  group('CoreScopeService.fetchCounts', () {
    test('found: parses observer + observation counts', () async {
      late Uri captured;
      final service = CoreScopeService(
        host: 'map.okimesh.org',
        client: MockClient((req) async {
          captured = req.url;
          return http.Response(
            '{"packets":[{"hash":"abc123","observer_count":15,'
            '"observation_count":34}],"total":1}',
            200,
          );
        }),
      );

      final result = await service.fetchCounts('abc123');
      expect(result.status, CoreScopeStatus.found);
      expect(result.counts!.observers, 15);
      expect(result.counts!.observations, 34);
      expect(captured.host, 'map.okimesh.org');
      expect(captured.path, '/api/packets');
      expect(captured.queryParameters['hash'], 'abc123');
      expect(captured.queryParameters['groupByHash'], 'true');
    });

    test('found: observations falls back to observers when absent', () async {
      final service = CoreScopeService(
        client: MockClient(
          (_) async => http.Response('{"packets":[{"observer_count":9}]}', 200),
        ),
      );
      final result = await service.fetchCounts('abc123');
      expect(result.status, CoreScopeStatus.found);
      expect(result.counts!.observers, 9);
      expect(result.counts!.observations, 9);
    });

    test('notFound: reachable but empty packets (the #571 case)', () async {
      final service = CoreScopeService(
        client: MockClient(
          (_) async => http.Response('{"packets":[],"total":0}', 200),
        ),
      );
      final result = await service.fetchCounts('deadbeef');
      expect(result.status, CoreScopeStatus.notFound);
      expect(result.counts, isNull);
    });

    test('unreachable on non-200', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('nope', 503)),
      );
      expect(
        (await service.fetchCounts('abc123')).status,
        CoreScopeStatus.unreachable,
      );
    });

    test('unreachable on malformed body', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      expect(
        (await service.fetchCounts('abc123')).status,
        CoreScopeStatus.unreachable,
      );
    });

    test('unreachable (never throws) on transport failure', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      expect(
        (await service.fetchCounts('abc123')).status,
        CoreScopeStatus.unreachable,
      );
    });

    test('empty hash: unreachable without hitting the network', () async {
      var called = false;
      final service = CoreScopeService(
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );
      expect(
        (await service.fetchCounts('')).status,
        CoreScopeStatus.unreachable,
      );
      expect(called, isFalse);
    });
  });
}
