import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Per-channel region scope, persisted per device (Feature #812, Epic #815).
///
/// Stores the region name a channel's outgoing messages should ride, keyed by
/// the first 10 hex chars of the connected device's public key (the same
/// scoping the other channel stores use). The name is the `#`-stripped region
/// name from discovery; null/absent means the channel is unscoped.
class ChannelRegionScopeStore {
  static const String _keyPrefix = 'channel_region_scope_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String _key(int channelIndex) => '$_keyPrefix${publicKeyHex}_$channelIndex';

  /// The region name scoping [channelIndex], or null when unscoped.
  Future<String?> scopeFor(int channelIndex) async {
    if (publicKeyHex.isEmpty) return null;
    return PrefsManager.instance.getString(_key(channelIndex));
  }

  /// Scope [channelIndex] to [regionName].
  Future<void> setScope(int channelIndex, String regionName) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('No device key set; cannot save channel region scope.');
      return;
    }
    await PrefsManager.instance.setString(_key(channelIndex), regionName);
  }

  /// Remove the region scope on [channelIndex] (back to unscoped).
  Future<void> clearScope(int channelIndex) async {
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.remove(_key(channelIndex));
  }
}
