import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/config_catalog.dart';

void main() {
  group('parseCatalog', () {
    test('parses entries and exposes published only', () {
      final c = parseCatalog('''
{
  "manifest_version": 1,
  "profiles": [
    {"name": "A", "url": "https://x/a.yaml", "status": "published", "region": "IAD", "schema_version": 1},
    {"name": "B", "url": "https://x/b.yaml", "status": "retired"},
    {"name": "C", "url": "https://x/c.yaml"}
  ]
}
''');
      expect(c.manifestVersion, 1);
      expect(c.entries.length, 3);
      // published + status-omitted (C) show; retired (B) hidden
      expect(c.published.map((e) => e.name), ['A', 'C']);
      expect(c.entries.first.region, 'IAD');
    });

    test('skips malformed entries without failing the catalog', () {
      final c = parseCatalog('''
{
  "manifest_version": 1,
  "profiles": [
    {"name": "ok", "url": "https://x/a.yaml"},
    {"name": "no-url"},
    {"url": "https://x/no-name.yaml"},
    "not-an-object"
  ]
}
''');
      expect(c.entries.length, 1);
      expect(c.skippedEntries, 3);
    });

    test('unrecognized status is hidden', () {
      final c = parseCatalog(
        '{"manifest_version":1,"profiles":[{"name":"x","url":"https://x/x.yaml","status":"draft"}]}',
      );
      expect(c.entries.single.status, CatalogStatus.unknown);
      expect(c.published, isEmpty);
    });

    test('rejects bad JSON', () {
      expect(
        () => parseCatalog('{not json'),
        throwsA(isA<ConfigCatalogFormatException>()),
      );
    });

    test('requires manifest_version', () {
      expect(
        () => parseCatalog('{"profiles":[]}'),
        throwsA(isA<ConfigCatalogFormatException>()),
      );
    });

    test('rejects a newer manifest_version', () {
      expect(
        () => parseCatalog('{"manifest_version":999,"profiles":[]}'),
        throwsA(isA<ConfigCatalogFormatException>()),
      );
    });
  });
}
