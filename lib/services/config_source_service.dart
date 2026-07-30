import 'package:http/http.dart' as http;

import '../helpers/config_profile_parser.dart';
import '../models/config_catalog.dart';
import '../models/config_profile.dart';

/// Fetches config profiles from a remote source (#404): the curated Offband
/// catalog, or any region's self-hosted catalog / single profile.
///
/// Device-agnostic — observer (#139), repeater (#137), and companion (#138)
/// share this. Only the apply step differs per device.

/// Default curated catalog (repo: OffbandMesh/config-profiles).
const String kDefaultCatalogUrl =
    'https://raw.githubusercontent.com/OffbandMesh/config-profiles/main/profiles.json';

/// What a user-entered URL points at, decided by its tail.
enum SourceKind { catalog, profile }

class ResolvedSource {
  const ResolvedSource(this.kind, this.url);
  final SourceKind kind;

  /// The URL to actually fetch (may differ from the input — a directory URL
  /// resolves to `<dir>/profiles.json`).
  final String url;
}

/// Thrown on any fetch/decode failure; message is user-facing.
class ConfigSourceException implements Exception {
  const ConfigSourceException(this.message);
  final String message;
  @override
  String toString() => 'ConfigSourceException: $message';
}

/// Resolve a user-entered URL by its tail (no reliance on HTTP directory
/// listing):
/// - ends `.json` -> a catalog manifest
/// - ends `.yaml` / `.yml` -> a single profile
/// - otherwise (trailing `/` or no filename) -> `<url>profiles.json`
ResolvedSource resolveSourceUrl(String input) {
  final trimmed = input.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw const ConfigSourceException(
      'Enter a full http(s) URL to a catalog or a .yaml profile',
    );
  }

  final lower = trimmed.toLowerCase();
  if (lower.endsWith('.json')) {
    return ResolvedSource(SourceKind.catalog, trimmed);
  }
  if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
    return ResolvedSource(SourceKind.profile, trimmed);
  }
  // Directory / bare host: append the conventional manifest filename.
  final base = trimmed.endsWith('/') ? trimmed : '$trimmed/';
  return ResolvedSource(SourceKind.catalog, '${base}profiles.json');
}

class ConfigSourceService {
  ConfigSourceService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Fetch + parse a catalog manifest.
  Future<ConfigCatalog> fetchCatalog(String url) async {
    return parseCatalog(await _get(url));
  }

  /// Fetch + parse a single profile YAML.
  Future<ConfigProfile> fetchProfile(String url) async {
    return parseConfigProfile(await _get(url));
  }

  Future<String> _get(String url) async {
    final http.Response resp;
    try {
      // Cache-bust: config fetches must never serve a stale catalog/profile
      // (raw.githubusercontent sits behind a CDN with a multi-minute TTL, so a
      // re-import right after a catalog edit could otherwise return the old
      // file). A unique query param guarantees a cache miss; the no-cache
      // headers are belt-and-braces.
      final base = Uri.parse(url);
      final busted = base.replace(
        queryParameters: {
          ...base.queryParameters,
          '_': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      resp = await _client.get(
        busted,
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      );
    } catch (e) {
      throw ConfigSourceException('Could not reach $url: $e');
    }
    if (resp.statusCode != 200) {
      throw ConfigSourceException('$url returned HTTP ${resp.statusCode}');
    }
    if (resp.body.isEmpty) {
      throw ConfigSourceException('$url returned an empty response');
    }
    return resp.body;
  }

  void dispose() => _client.close();
}
