import 'dart:convert';

// Catalog manifest model (#404): the `profiles.json` a source publishes.
//
// Schema is documented in the `OffbandMesh/config-profiles` repo (SCHEMA.md).
// Parsing is resilient — a single malformed entry is skipped rather than
// failing the whole catalog — but a manifest that isn't JSON, or declares a
// newer `manifest_version` than we support, is rejected outright.

/// Highest manifest_version this build understands.
const int kCatalogManifestVersion = 1;

/// Thrown when a manifest cannot be used at all (bad JSON / unsupported version).
class ConfigCatalogFormatException implements Exception {
  const ConfigCatalogFormatException(this.message);
  final String message;
  @override
  String toString() => 'ConfigCatalogFormatException: $message';
}

enum CatalogStatus {
  published,
  retired,

  /// A status string this build doesn't recognize. Treated as not-published so
  /// an unknown future status never accidentally surfaces in the picker.
  unknown;

  static CatalogStatus fromWire(String? v) {
    switch (v) {
      case 'published':
        return CatalogStatus.published;
      case 'retired':
        return CatalogStatus.retired;
      default:
        return CatalogStatus.unknown;
    }
  }
}

/// One catalog entry. [name] and [url] are required; the rest are hints.
class CatalogEntry {
  const CatalogEntry({
    required this.name,
    required this.url,
    this.description,
    this.region,
    this.schemaVersion,
    this.status = CatalogStatus.published,
  });

  final String name;
  final String url;
  final String? description;
  final String? region;
  final int? schemaVersion;
  final CatalogStatus status;
}

class ConfigCatalog {
  const ConfigCatalog({
    required this.manifestVersion,
    required this.entries,
    this.skippedEntries = 0,
  });

  final int manifestVersion;
  final List<CatalogEntry> entries;

  /// Count of malformed entries skipped during parse — surfaced so a partly-bad
  /// catalog doesn't look complete (no silent truncation).
  final int skippedEntries;

  /// Entries the app should offer in the picker.
  List<CatalogEntry> get published =>
      entries.where((e) => e.status == CatalogStatus.published).toList();
}

/// Parse a `profiles.json` manifest. Throws [ConfigCatalogFormatException] for a
/// manifest that can't be used; skips individual malformed entries.
ConfigCatalog parseCatalog(String source) {
  final dynamic doc;
  try {
    doc = jsonDecode(source);
  } on FormatException catch (e) {
    throw ConfigCatalogFormatException('Not valid JSON: ${e.message}');
  }
  if (doc is! Map) {
    throw const ConfigCatalogFormatException('manifest must be a JSON object');
  }

  final version = doc['manifest_version'];
  if (version is! int) {
    throw const ConfigCatalogFormatException(
      'manifest_version is required and must be an integer',
    );
  }
  if (version > kCatalogManifestVersion) {
    throw ConfigCatalogFormatException(
      'manifest_version $version is newer than this app supports '
      '($kCatalogManifestVersion). Update the app.',
    );
  }

  final rawProfiles = doc['profiles'];
  if (rawProfiles != null && rawProfiles is! List) {
    throw const ConfigCatalogFormatException('"profiles" must be a list');
  }

  final entries = <CatalogEntry>[];
  var skipped = 0;
  for (final raw in (rawProfiles as List? ?? const [])) {
    if (raw is! Map) {
      skipped++;
      continue;
    }
    final name = raw['name'];
    final url = raw['url'];
    if (name is! String || name.isEmpty || url is! String || url.isEmpty) {
      skipped++; // name + url are the minimum an entry must carry
      continue;
    }
    entries.add(
      CatalogEntry(
        name: name,
        url: url,
        description: raw['description'] is String
            ? raw['description'] as String
            : null,
        region: raw['region'] is String ? raw['region'] as String : null,
        schemaVersion: raw['schema_version'] is int
            ? raw['schema_version'] as int
            : null,
        // Absent status = published (author just omitted it). A present-but-
        // unrecognized status resolves to unknown and is hidden (forward-safe).
        status: raw.containsKey('status')
            ? CatalogStatus.fromWire(
                raw['status'] is String ? raw['status'] as String : null,
              )
            : CatalogStatus.published,
      ),
    );
  }

  return ConfigCatalog(
    manifestVersion: version,
    entries: entries,
    skippedEntries: skipped,
  );
}
