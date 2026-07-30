import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:meshcore_open/models/config_profile.dart';
import 'package:meshcore_open/services/config_source_service.dart';

void main() {
  group('resolveSourceUrl (tail-detection)', () {
    test('.json -> catalog, unchanged', () {
      final r = resolveSourceUrl('https://h/dir/profiles.json');
      expect(r.kind, SourceKind.catalog);
      expect(r.url, 'https://h/dir/profiles.json');
    });

    test('.yaml / .yml -> profile, unchanged', () {
      expect(resolveSourceUrl('https://h/p.yaml').kind, SourceKind.profile);
      expect(resolveSourceUrl('https://h/p.yml').kind, SourceKind.profile);
    });

    test('trailing slash -> <dir>/profiles.json', () {
      final r = resolveSourceUrl('https://h/dir/');
      expect(r.kind, SourceKind.catalog);
      expect(r.url, 'https://h/dir/profiles.json');
    });

    test('bare host / no filename -> profiles.json appended', () {
      final r = resolveSourceUrl('https://h/dir');
      expect(r.kind, SourceKind.catalog);
      expect(r.url, 'https://h/dir/profiles.json');
    });

    test('case-insensitive extension', () {
      expect(resolveSourceUrl('https://h/P.YAML').kind, SourceKind.profile);
      expect(resolveSourceUrl('https://h/M.JSON').kind, SourceKind.catalog);
    });

    test('rejects non-http input', () {
      expect(
        () => resolveSourceUrl('ftp://h/x.yaml'),
        throwsA(isA<ConfigSourceException>()),
      );
      expect(
        () => resolveSourceUrl('not a url'),
        throwsA(isA<ConfigSourceException>()),
      );
    });
  });

  group('ConfigSourceService fetch', () {
    test('fetchProfile parses a served YAML', () async {
      final svc = ConfigSourceService(
        client: MockClient((req) async {
          return http.Response(
            'schema_version: 2\nmqtt:\n  region: IAD\n',
            200,
          );
        }),
      );
      final p = await svc.fetchProfile('https://h/p.yaml');
      expect(p, isA<ConfigProfile>());
      expect(p.mqtt?.regionIata, 'IAD');
    });

    test('fetchCatalog parses a served manifest', () async {
      final svc = ConfigSourceService(
        client: MockClient((req) async {
          return http.Response(
            '{"manifest_version":1,"profiles":[{"name":"A","url":"https://h/a.yaml"}]}',
            200,
          );
        }),
      );
      final c = await svc.fetchCatalog('https://h/profiles.json');
      expect(c.published.single.name, 'A');
    });

    test('non-200 throws ConfigSourceException', () async {
      final svc = ConfigSourceService(
        client: MockClient((req) async => http.Response('nope', 404)),
      );
      expect(
        () => svc.fetchProfile('https://h/missing.yaml'),
        throwsA(isA<ConfigSourceException>()),
      );
    });

    test('empty body throws ConfigSourceException', () async {
      final svc = ConfigSourceService(
        client: MockClient((req) async => http.Response('', 200)),
      );
      expect(
        () => svc.fetchCatalog('https://h/profiles.json'),
        throwsA(isA<ConfigSourceException>()),
      );
    });
  });
}
