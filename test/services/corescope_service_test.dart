import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/services/corescope_service.dart';

void main() {
  group('CoreScopeService.fetchObserverCount', () {
    test('parses observer_count from a grouped-by-hash response', () async {
      late Uri captured;
      final service = CoreScopeService(
        host: 'map.okimesh.org',
        client: MockClient((req) async {
          captured = req.url;
          return http.Response(
            '{"packets":[{"hash":"abc123","observer_count":7}],"total":1}',
            200,
          );
        }),
      );

      expect(await service.fetchObserverCount('abc123'), 7);
      // Correct endpoint + query built from the hash.
      expect(captured.scheme, 'https');
      expect(captured.host, 'map.okimesh.org');
      expect(captured.path, '/api/packets');
      expect(captured.queryParameters['hash'], 'abc123');
      expect(captured.queryParameters['groupByHash'], 'true');
    });

    test('returns null when CoreScope has no record (empty packets)', () async {
      final service = CoreScopeService(
        client: MockClient(
          (_) async => http.Response('{"packets":[],"total":0}', 200),
        ),
      );
      expect(await service.fetchObserverCount('deadbeef'), isNull);
    });

    test('returns null on non-200', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('nope', 503)),
      );
      expect(await service.fetchObserverCount('abc123'), isNull);
    });

    test('returns null on malformed body', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      expect(await service.fetchObserverCount('abc123'), isNull);
    });

    test('returns null (never throws) on transport failure', () async {
      final service = CoreScopeService(
        client: MockClient((_) async => throw Exception('offline')),
      );
      expect(await service.fetchObserverCount('abc123'), isNull);
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
        expect(await service.fetchObserverCount(''), isNull);
        expect(called, isFalse);
      },
    );
  });
}
