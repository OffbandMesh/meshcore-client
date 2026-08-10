import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';

/// Default CoreScope instance (OKIMesh). Owner-run; its read API is public.
const String kDefaultCoreScopeHost = 'map.okimesh.org';

/// Queries a CoreScope instance for how many observers reported a given packet,
/// keyed by the firmware/mesh packet hash (#524). Read-only and best-effort:
/// any failure (offline, timeout, non-200, bad body, unknown packet) returns
/// null so the chat UI can silently fall back to radio-only. Never throws.
class CoreScopeService {
  CoreScopeService({
    http.Client? client,
    this.host = kDefaultCoreScopeHost,
    this.useTls = true,
    this.timeout = const Duration(seconds: 6),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String host;
  final bool useTls;
  final Duration timeout;

  /// Unique observers that reported the packet with [packetHash]
  /// (16 lowercase hex chars). Returns null on any error, or when CoreScope
  /// has no record of the hash yet.
  Future<int?> fetchObserverCount(String packetHash) async {
    if (packetHash.isEmpty) return null;
    final uri = Uri(
      scheme: useTls ? 'https' : 'http',
      host: host,
      path: '/api/packets',
      queryParameters: {
        'hash': packetHash,
        'groupByHash': 'true',
        'limit': '1',
      },
    );
    appLogger.info('GET $uri', tag: 'CoreScope');
    try {
      final resp = await _client.get(uri).timeout(timeout);
      if (resp.statusCode != 200) {
        appLogger.warn(
          'HTTP ${resp.statusCode} for hash $packetHash',
          tag: 'CoreScope',
        );
        return null;
      }
      final body = jsonDecode(resp.body);
      if (body is! Map) return null;
      final packets = body['packets'];
      if (packets is! List || packets.isEmpty) {
        appLogger.info('no record yet for $packetHash', tag: 'CoreScope');
        return null;
      }
      final first = packets.first;
      if (first is! Map) return null;
      final count = first['observer_count'];
      final result = count is num ? count.toInt() : null;
      appLogger.info(
        'observer_count=$result for $packetHash',
        tag: 'CoreScope',
      );
      return result;
    } catch (e) {
      appLogger.warn('Query failed for $packetHash: $e', tag: 'CoreScope');
      return null;
    }
  }

  void dispose() => _client.close();
}
