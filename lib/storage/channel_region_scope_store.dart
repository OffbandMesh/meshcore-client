import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Per-channel region scope, persisted per device (Feature #812, Epic #815).
///
/// Keyed by the channel **PSK** (the channel's identity), scoped per device by
/// the first 10 hex chars of the connected device's public key. A slot
/// reshuffle on sync cannot move a scope to the wrong channel, because the key
/// is the PSK, not the slot index (#1256). Falls back to the slot-index key
/// only while the PSK is unknown (channel list not yet loaded), mirroring
/// `channel_message_store` (#194). The name is the `#`-stripped region name
/// from discovery; null/absent means the channel is unscoped.
class ChannelRegionScopeStore {
  static const String _keyPrefix = 'channel_region_scope_';
  static const String _pskMarker = 'psk_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  /// Resolves a slot index to the channel's PSK hex, or null while unknown.
  /// Mirrors `channel_message_store.channelPskResolver` (#194/#1062).
  String? Function(int index)? channelPskResolver;

  String _indexKey(int channelIndex) =>
      '$_keyPrefix${publicKeyHex}_$channelIndex';
  String _pskKey(String pskHex) =>
      '$_keyPrefix${publicKeyHex}_$_pskMarker$pskHex';

  /// Active key: the PSK identity when known, else the slot index. A fallback
  /// to the index key while a resolver exists means the channel list was not
  /// loaded first; it reads a DIFFERENT key, so it is logged, never silent
  /// (SAFELANE 6).
  String _activeKey(int channelIndex, {bool forWrite = false}) {
    final pskHex = channelPskResolver?.call(channelIndex);
    if (pskHex != null && pskHex.isNotEmpty) {
      return _pskKey(pskHex);
    }
    if (channelPskResolver != null) {
      if (forWrite) {
        appLogger.error(
          'Region-scope WRITE for channel $channelIndex fell back to the '
          'slot-index key: the slot did not resolve to a PSK. (#1256)',
          tag: 'Storage',
        );
      } else {
        appLogger.warn(
          'Region scope for channel $channelIndex has no PSK yet; falling '
          'back to the slot-index key. The channel list was not loaded first. '
          '(#1256)',
          tag: 'Storage',
        );
      }
    }
    return _indexKey(channelIndex);
  }

  /// The region name scoping [channelIndex], or null when unscoped.
  Future<String?> scopeFor(int channelIndex) async {
    if (publicKeyHex.isEmpty) return null;
    final key = _activeKey(channelIndex);
    final value = PrefsManager.instance.getString(key);
    if (value != null && value.isNotEmpty) return value;

    // One-time best-effort migration into the PSK-identity key: when the PSK is
    // known and the PSK key is empty, adopt a pre-#1256 slot-index value and
    // drop the source. Maps the current index to the PSK (owner: best-effort;
    // an already-reshuffled scope binds to the current occupant once).
    final indexKey = _indexKey(channelIndex);
    if (key != indexKey) {
      final legacy = PrefsManager.instance.getString(indexKey);
      if (legacy != null && legacy.isNotEmpty) {
        appLogger.info(
          'Migrating region scope $indexKey -> $key (PSK-keyed, #1256)',
          tag: 'Storage',
        );
        await PrefsManager.instance.setString(key, legacy);
        await PrefsManager.instance.remove(indexKey);
        return legacy;
      }
    }
    return null;
  }

  /// Scope [channelIndex] to [regionName].
  Future<void> setScope(int channelIndex, String regionName) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('No device key set; cannot save channel region scope.');
      return;
    }
    final key = _activeKey(channelIndex, forWrite: true);
    await PrefsManager.instance.setString(key, regionName);
    // Kill any stale pre-#1256 index-keyed value so it can never be re-adopted
    // after this PSK scope is later cleared.
    final indexKey = _indexKey(channelIndex);
    if (key != indexKey) await PrefsManager.instance.remove(indexKey);
  }

  /// Remove the region scope on [channelIndex] (back to unscoped).
  Future<void> clearScope(int channelIndex) async {
    if (publicKeyHex.isEmpty) return;
    final key = _activeKey(channelIndex, forWrite: true);
    await PrefsManager.instance.remove(key);
    final indexKey = _indexKey(channelIndex);
    if (key != indexKey) await PrefsManager.instance.remove(indexKey);
  }
}
