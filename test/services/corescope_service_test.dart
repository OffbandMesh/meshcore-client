import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/corescope_service.dart';

void main() {
  group('CoreScopeService.fetchCounts', () {
    test(
      'parses observer + observation counts from a grouped response',
      () async {
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

        final counts = await service.fetchCounts('abc123');
        expect(counts, isNotNull);
        expect(counts!.observers, 15);
        expect(counts.observations, 34);
        expect(captured.host, 'map.okimesh.org');
        expect(captured.path, '/api/packets');
        expect(captured.queryParameters['hash'], 'abc123');
        expect(captured.queryParameters['groupByHash'], 'true');
      },
    );

    test('falls back to observers when observation_count is absent', () async {
      final service = CoreScopeService(
        client: MockClient(
          (_) async => http.Response('{"packets":[{"observer_count":9}]}', 200),
        ),
      );
      final counts = await service.fetchCounts('abc123');
      expect(counts!.observers, 9);
      expect(counts.observations, 9);
    });

    test('returns null when CoreScope has no record (empty packets)', () async {
      final service = CoreScopeService(
        client: MockClient(
          (_) async => http.Response('{"packets":[],"total":0}', 200),
        ),
      );
      expect(await service.fetchCounts('deadbeef'), isNull);
    });

    test('returns null on non-200', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('nope', 503)),
      );
      expect(await service.fetchCounts('abc123'), isNull);
    });

    test('returns null on malformed body', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      expect(await service.fetchCounts('abc123'), isNull);
    });

    test('returns null (never throws) on transport failure', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      expect(await service.fetchCounts('abc123'), isNull);
    });

    test(
      'returns null for an empty hash without hitting the network',
      () async {
        var called = false;
        final service = CoreScopeService(
          client: MockClient((_) async {
            called = true;
            return http.Response('{}', 200);
          }),
        );
        expect(await service.fetchCounts(''), isNull);
        expect(called, isFalse);
      },
    );
  });
}
