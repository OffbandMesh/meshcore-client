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

  String? _selfKeyHex;

  /// The connected node's own public key, injected by the connector once it is
  /// learned and cleared on disconnect. Blocking yourself silently hides your
  /// own traffic with no way to see why, so every add path refuses it (#250).
  String? get selfKeyHex => _selfKeyHex;

  bool isSelf(String publicKeyHex) {
    final self = _selfKeyHex;
    return self != null && publicKeyHex.toLowerCase() == self;
  }

  /// Called by the connector when the self key is learned (or cleared). If the
  /// self key is already stored, blocked before this guard existed, or pulled
  /// in from the radio's list, drop it here and tell the radio to remove it.
  Future<void> setSelfKey(String? publicKeyHex) async {
    final key = publicKeyHex?.toLowerCase();
    final normalized = (key == null || key.isEmpty) ? null : key;
    final changed = normalized != _selfKeyHex;
    _selfKeyHex = normalized;
    // Heal even when the key is unchanged, a self-block can appear after the
    // key is already known (a union pull racing self-info, or a stale store),
    // and an unchanged-key early return would strand it.
    final healed = normalized != null && _blockedKeys.remove(normalized);
    if (healed) firmwareSync?.call(normalized, false);
    if (changed || healed) notifyListeners();
    // Everything above is synchronous, so a caller that doesn't await this
    // still observes consistent state immediately; only the write is deferred.
    if (healed) await _store.saveKeys(_blockedKeys);
  }

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
    if (isSelf(key)) return;
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
  /// Never removes, the union only adds.
  Future<void> importKeys(Iterable<String> keysHex) async {
    var changed = false;
    for (final k in keysHex) {
      final key = k.toLowerCase();
      // A self-block already pushed to the radio must not come back via the
      // union pull (#250).
      if (isSelf(key)) continue;
      if (_blockedKeys.add(key)) changed = true;
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
    // Your own name resolving to your own key must not promote into a
    // self-block, drop the name block and stop (#250).
    if (isSelf(key)) {
      await _store.saveNames(_blockedNames);
      notifyListeners();
      return;
    }
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
