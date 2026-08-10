import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';

/// Default CoreScope instance (OKIMesh). Owner-run; its read API is public.
const String kDefaultCoreScopeHost = 'map.okimesh.org';

/// The two counts CoreScope reports for a packet. [observers] is the number of
/// distinct observers (the meaningful reach); [observations] is the total
/// sightings, which counts one observer hearing the packet via several paths
/// more than once (this is the "Observations (N)" number in CoreScope's UI).
class CoreScopeCounts {
  const CoreScopeCounts({required this.observers, required this.observations});
  final int observers;
  final int observations;
}

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

  /// Distinct observers and total observations for [packetHash] (16 lowercase
  /// hex chars). Returns null on any error, or when CoreScope has no record of
  /// the hash yet.
  Future<CoreScopeCounts?> fetchCounts(String packetHash) async {
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
      final observers = first['observer_count'];
      if (observers is! num) return null;
      final observations = first['observation_count'];
      final counts = CoreScopeCounts(
        observers: observers.toInt(),
        observations: observations is num
            ? observations.toInt()
            : observers.toInt(),
      );
      appLogger.info(
        'observers=${counts.observers} observations=${counts.observations} '
        'for $packetHash',
        tag: 'CoreScope',
      );
      return counts;
    } catch (e) {
      appLogger.warn('Query failed for $packetHash: $e', tag: 'CoreScope');
      return null;
    }
  }

  void dispose() => _client.close();
}
