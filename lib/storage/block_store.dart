import 'dart:convert';

import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Per-radio persistence for the block list.
///
/// Scoped by the connected device key (first 10 hex chars), like the app's
/// other stores. A block belongs to the radio it was set on: the app is the
/// enforcer and registry even on firmware that can't offload, and clearing a
/// radio must stay cleared. There is intentionally **no** global list; a
/// global list unioned across radios re-infects a cleared radio (#471).
///
/// The pre-#471 build stored one unscoped global list (`block_keys_v1` /
/// `block_names_v1`). That is dropped, not migrated (owner decision, #471):
/// the feature is new and the global list was the source of the stray
/// self-block. See `docs/architecture/block-contract-as-built.md`.
class BlockStore {
  static const String _keysPrefix = 'block_keys_v1';
  static const String _namesPrefix = 'block_names_v1';

  /// First 10 hex chars of the connected device key. Empty when no radio is
  /// connected; loads/saves are no-ops in that state.
  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String get _keysKey => '$_keysPrefix$publicKeyHex';
  String get _namesKey => '$_namesPrefix$publicKeyHex';

  /// Delete the legacy unscoped global list. Idempotent, cheap after the first
  /// run (the guarded reads avoid a prefs rewrite when the keys are absent).
  /// Drop-and-start-fresh: the global list is not migrated onto any radio.
  Future<void> dropLegacyGlobal() async {
    final prefs = PrefsManager.instance;
    if (prefs.get(_keysPrefix) != null) {
      appLogger.info('Dropping legacy global block key list (#471)');
      await prefs.remove(_keysPrefix);
    }
    if (prefs.get(_namesPrefix) != null) {
      appLogger.info('Dropping legacy global block name list (#471)');
      await prefs.remove(_namesPrefix);
    }
  }

  /// Blocked public keys (lowercased hex) for the current radio.
  Future<Set<String>> loadKeys() async {
    if (publicKeyHex.isEmpty) return {};
    final list = PrefsManager.instance.getStringList(_keysKey) ?? const [];
    return list.map((k) => k.toLowerCase()).toSet();
  }

  Future<void> saveKeys(Set<String> keys) async {
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.setStringList(_keysKey, keys.toList());
  }

  /// Name-only blocks: lowercased claimed name -> first-blocked epoch millis.
  /// The timestamp feeds the promote-and-prune age-out (Epic A / A7).
  Future<Map<String, int>> loadNames() async {
    if (publicKeyHex.isEmpty) return {};
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
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.setString(_namesKey, jsonEncode(names));
  }
}
