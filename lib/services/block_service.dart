import 'package:flutter/foundation.dart';

import '../storage/block_store.dart';

/// Per-radio block list, backed by [BlockStore] and exposed to the UI.
///
/// Source of truth for the client: DMs + adverts are filtered by public key,
/// channel posts by resolved key or claimed name. Always active regardless of
/// firmware; the firmware offload (Epic B) mirrors this, never replaces it.
///
/// The set is scoped to the connected radio and swapped by [loadForDevice] on
/// connect; a block set on one radio never leaks to another, and clearing a
/// radio stays cleared (#471). There is no global list.
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

  /// Serializes all state-mutating operations so they can't interleave. The
  /// connector fires [loadForDevice] (on connect) and [importKeys] (from the
  /// block LIST dump) without awaiting, and they land in different frame
  /// handlers; without this chain, loadForDevice's clear+reload could wipe keys
  /// importKeys just added, or vice-versa (#471). Runs each op strictly after
  /// the previous one settles; failures don't stall the chain.
  Future<void> _opChain = Future<void>.value();
  Future<T> _serialize<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  String? _selfKeyHex;

  /// The connected node's own public key, injected by the connector once it is
  /// learned and cleared on disconnect. Blocking yourself silently hides your
  /// own traffic with no way to see why, so every add path refuses it (#250).
  String? get selfKeyHex => _selfKeyHex;

  bool isSelf(String publicKeyHex) {
    final self = _selfKeyHex;
    return self != null && publicKeyHex.toLowerCase() == self;
  }

  /// Call once during app startup. Drops the legacy unscoped global list
  /// (#471, drop-and-start-fresh) and starts empty; the real per-radio list
  /// loads via [loadForDevice] when a radio connects.
  Future<void> load() => _serialize(() async {
    await _store.dropLegacyGlobal();
    _blockedKeys.clear();
    _blockedNames.clear();
    _selfKeyHex = null;
    notifyListeners();
  });

  /// (Re)load the block list for the connected radio, keyed by [deviceKeyHex]
  /// (null on disconnect). Called by the connector when the device key is
  /// learned or changes. Swaps the in-memory set so a block set on one radio
  /// never leaks to another, and runs the #250 self-heal for this radio's own
  /// key. Serialized against [importKeys] so a concurrent block LIST dump can
  /// neither be wiped by the reload nor wipe it (#471).
  Future<void> loadForDevice(String? deviceKeyHex) => _serialize(() async {
    final key = deviceKeyHex?.toLowerCase();
    final normalized = (key == null || key.isEmpty) ? null : key;
    _store.setPublicKeyHex = normalized ?? '';
    _selfKeyHex = normalized;
    await _store.dropLegacyGlobal();
    _blockedKeys
      ..clear()
      ..addAll(await _store.loadKeys());
    _blockedNames
      ..clear()
      ..addAll(await _store.loadNames());
    await _pruneExpiredNames();
    // Self-heal: never keep the connected radio's own key in its own list
    // (blocking yourself silently hides your own traffic, #250).
    if (normalized != null && _blockedKeys.remove(normalized)) {
      await _store.saveKeys(_blockedKeys);
      firmwareSync?.call(normalized, false);
    }
    notifyListeners();
  });

  Set<String> get blockedKeys => Set.unmodifiable(_blockedKeys);
  Map<String, int> get blockedNames => Map.unmodifiable(_blockedNames);

  bool isBlocked(String publicKeyHex) =>
      _blockedKeys.contains(publicKeyHex.toLowerCase());

  bool isNameBlocked(String name) =>
      _blockedNames.containsKey(name.trim().toLowerCase());

  Future<void> block(String publicKeyHex) => _serialize(() async {
    final key = publicKeyHex.toLowerCase();
    if (isSelf(key)) return;
    if (!_blockedKeys.add(key)) return;
    await _store.saveKeys(_blockedKeys);
    firmwareSync?.call(key, true);
    notifyListeners();
  });

  Future<void> unblock(String publicKeyHex) => _serialize(() async {
    final key = publicKeyHex.toLowerCase();
    if (!_blockedKeys.remove(key)) return;
    await _store.saveKeys(_blockedKeys);
    firmwareSync?.call(key, false);
    notifyListeners();
  });

  /// Merge keys learned from the firmware block list into the local set WITHOUT
  /// echoing them back to the radio (used by the connect-time union pull).
  /// Never removes, the union only adds. Serialized against [loadForDevice] so
  /// a reload can't wipe these imports and vice-versa (#471).
  Future<void> importKeys(Iterable<String> keysHex) => _serialize(() async {
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
  });

  Future<void> blockName(String name) => _serialize(() async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty || _blockedNames.containsKey(n)) return;
    _blockedNames[n] = DateTime.now().millisecondsSinceEpoch;
    await _store.saveNames(_blockedNames);
    notifyListeners();
  });

  Future<void> unblockName(String name) => _serialize(() async {
    if (_blockedNames.remove(name.trim().toLowerCase()) == null) return;
    await _store.saveNames(_blockedNames);
    notifyListeners();
  });

  /// Name-only blocks older than this are pruned on load (self-cleaning).
  static const Duration _nameBlockTtl = Duration(days: 30);

  /// Promote a name-only block to a durable pubkey block once we learn the
  /// identity behind it (observed via an advert or a DM). No-op if the name
  /// isn't name-blocked.
  Future<void> maybePromote(String name, String publicKeyHex) =>
      _serialize(() async {
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
      });

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
