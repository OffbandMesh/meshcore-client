import 'dart:convert';

import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Persistence for the app-global block list.
///
/// Deliberately **global** — unlike the other stores it is NOT scoped by the
/// connected device key. A block is "I don't want to see this person," keyed by
/// their public key, and must hold regardless of which radio is connected.
/// See `docs/architecture/block-contract-as-built.md`.
class BlockStore {
  static const String _keysKey = 'block_keys_v1';
  static const String _namesKey = 'block_names_v1';

  /// Blocked public keys (lowercased hex).
  Future<Set<String>> loadKeys() async {
    final list = PrefsManager.instance.getStringList(_keysKey) ?? const [];
    return list.map((k) => k.toLowerCase()).toSet();
  }

  Future<void> saveKeys(Set<String> keys) async {
    await PrefsManager.instance.setStringList(_keysKey, keys.toList());
  }

  /// Name-only blocks: lowercased claimed name -> first-blocked epoch millis.
  /// The timestamp feeds the promote-and-prune age-out (Epic A / A7).
  Future<Map<String, int>> loadNames() async {
    final raw = PrefsManager.instance.getString(_namesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (e) {
      appLogger.error('Failed to decode blocked names: $e');
      return {};
    }
  }

  Future<void> saveNames(Map<String, int> names) async {
    await PrefsManager.instance.setString(_namesKey, jsonEncode(names));
  }
}
