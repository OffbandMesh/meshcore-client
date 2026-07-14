import 'package:flutter/foundation.dart';

import '../storage/block_store.dart';

/// App-global block list, backed by [BlockStore] and exposed to the UI.
///
/// Source of truth for the client: DMs + adverts are filtered by public key,
/// channel posts by resolved key or claimed name. Always active regardless of
/// firmware; the firmware offload (Epic B) mirrors this, never replaces it.
/// See `docs/architecture/block-contract-as-built.md`.
class BlockService extends ChangeNotifier {
  BlockService({BlockStore? store}) : _store = store ?? BlockStore();

  final BlockStore _store;

  final Set<String> _blockedKeys = {};
  final Map<String, int> _blockedNames = {};

  /// Set by the connector: pushes a single key change to the firmware block
  /// store when the connected radio supports it (Epic B). `blocked` = add vs
  /// remove. Fired only on an actual local change; NOT fired by [importKeys]
  /// (the pull side), so a synced key never echoes back to the radio.
  void Function(String keyHex, bool blocked)? firmwareSync;

  /// Load persisted state. Call once during app startup.
  Future<void> load() async {
    _blockedKeys
      ..clear()
      ..addAll(await _store.loadKeys());
    _blockedNames
      ..clear()
      ..addAll(await _store.loadNames());
    await _pruneExpiredNames();
    notifyListeners();
  }

  Set<String> get blockedKeys => Set.unmodifiable(_blockedKeys);
  Map<String, int> get blockedNames => Map.unmodifiable(_blockedNames);

  bool isBlocked(String publicKeyHex) =>
      _blockedKeys.contains(publicKeyHex.toLowerCase());

  bool isNameBlocked(String name) =>
      _blockedNames.containsKey(name.trim().toLowerCase());

  Future<void> block(String publicKeyHex) async {
    final key = publicKeyHex.toLowerCase();
    if (!_blockedKeys.add(key)) return;
    await _store.saveKeys(_blockedKeys);
    firmwareSync?.call(key, true);
    notifyListeners();
  }

  Future<void> unblock(String publicKeyHex) async {
    final key = publicKeyHex.toLowerCase();
    if (!_blockedKeys.remove(key)) return;
    await _store.saveKeys(_blockedKeys);
    firmwareSync?.call(key, false);
    notifyListeners();
  }

  /// Merge keys learned from the firmware block list into the local set WITHOUT
  /// echoing them back to the radio (used by the connect-time union pull).
  /// Never removes — the union only adds.
  Future<void> importKeys(Iterable<String> keysHex) async {
    var changed = false;
    for (final k in keysHex) {
      if (_blockedKeys.add(k.toLowerCase())) changed = true;
    }
    if (!changed) return;
    await _store.saveKeys(_blockedKeys);
    notifyListeners();
  }

  Future<void> blockName(String name) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty || _blockedNames.containsKey(n)) return;
    _blockedNames[n] = DateTime.now().millisecondsSinceEpoch;
    await _store.saveNames(_blockedNames);
    notifyListeners();
  }

  Future<void> unblockName(String name) async {
    if (_blockedNames.remove(name.trim().toLowerCase()) == null) return;
    await _store.saveNames(_blockedNames);
    notifyListeners();
  }

  /// Name-only blocks older than this are pruned on load (self-cleaning).
  static const Duration _nameBlockTtl = Duration(days: 30);

  /// Promote a name-only block to a durable pubkey block once we learn the
  /// identity behind it (observed via an advert or a DM). No-op if the name
  /// isn't name-blocked.
  Future<void> maybePromote(String name, String publicKeyHex) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty || !_blockedNames.containsKey(n)) return;
    final key = publicKeyHex.toLowerCase();
    _blockedNames.remove(n);
    final added = _blockedKeys.add(key);
    await _store.saveNames(_blockedNames);
    await _store.saveKeys(_blockedKeys);
    if (added) firmwareSync?.call(key, true);
    notifyListeners();
  }

  /// Drop name-only blocks that never linked to a pubkey within [_nameBlockTtl].
  Future<void> _pruneExpiredNames() async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - _nameBlockTtl.inMilliseconds;
    final expired = _blockedNames.entries
        .where((e) => e.value < cutoff)
        .map((e) => e.key)
        .toList();
    if (expired.isEmpty) return;
    for (final n in expired) {
      _blockedNames.remove(n);
    }
    await _store.saveNames(_blockedNames);
  }
}
