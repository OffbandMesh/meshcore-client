import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Per-channel Cyr2Lat settings, keyed by the channel **PSK** identity so a
/// slot reshuffle on sync cannot carry a setting to the wrong channel (#1257,
/// same fix as the region-scope store #1256). Falls back to the slot-index key
/// only while the PSK is unknown (channel list not yet loaded), mirroring
/// `channel_message_store` (#194), and best-effort migrates existing
/// index-keyed values on first read.
class ChannelSettingsStore {
  static const String _cyr2latKeyPrefix = 'channel_cyr2lat_';
  static const String _pskMarker = 'psk_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  /// Resolves a slot index to the channel's PSK hex, or null while unknown.
  String? Function(int index)? channelPskResolver;

  String get keyForCyr2Lat => '$_cyr2latKeyPrefix$publicKeyHex';

  String _enabledIndexKey(int i) => '$keyForCyr2Lat$i';
  String _enabledPskKey(String psk) => '$keyForCyr2Lat$_pskMarker$psk';
  String _profileIndexKey(int i) => '${keyForCyr2Lat}profile_$i';
  String _profilePskKey(String psk) =>
      '${keyForCyr2Lat}profile_$_pskMarker$psk';

  /// Active key: PSK identity when known, else the slot index (logged when a
  /// resolver exists but the slot has no PSK yet, so the fallback is never
  /// silent).
  String? _psk(int channelIndex, {bool forWrite = false}) {
    final pskHex = channelPskResolver?.call(channelIndex);
    if (pskHex != null && pskHex.isNotEmpty) return pskHex;
    if (channelPskResolver != null) {
      final verb = forWrite ? 'WRITE' : 'read';
      appLogger.warn(
        'Cyr2Lat $verb for channel $channelIndex has no PSK yet; falling back '
        'to the slot-index key. The channel list was not loaded first. (#1257)',
        tag: 'Storage',
      );
    }
    return null;
  }

  Future<bool> loadCyr2LatEnabled(int channelIndex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load channel Cyr2Lat settings.',
      );
      return false;
    }
    final prefs = PrefsManager.instance;
    final psk = _psk(channelIndex);
    final key = psk != null
        ? _enabledPskKey(psk)
        : _enabledIndexKey(channelIndex);
    final value = prefs.getBool(key);
    if (value != null) return value;
    final indexKey = _enabledIndexKey(channelIndex);
    if (key != indexKey) {
      final legacy = prefs.getBool(indexKey);
      if (legacy != null) {
        appLogger.info(
          'Migrating Cyr2Lat enabled $indexKey -> $key (PSK-keyed, #1257)',
          tag: 'Storage',
        );
        await prefs.setBool(key, legacy);
        await prefs.remove(indexKey);
        return legacy;
      }
    }
    return false;
  }

  Future<void> saveCyr2LatEnabled(int channelIndex, bool enabled) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save channel Cyr2Lat settings.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final psk = _psk(channelIndex, forWrite: true);
    final key = psk != null
        ? _enabledPskKey(psk)
        : _enabledIndexKey(channelIndex);
    await prefs.setBool(key, enabled);
    final indexKey = _enabledIndexKey(channelIndex);
    if (key != indexKey) await prefs.remove(indexKey);
  }

  Future<String?> loadCyr2LatProfileId(int channelIndex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load channel settings.',
      );
      return null;
    }
    final prefs = PrefsManager.instance;
    final psk = _psk(channelIndex);
    final key = psk != null
        ? _profilePskKey(psk)
        : _profileIndexKey(channelIndex);
    final value = prefs.getString(key);
    if (value != null && value.isNotEmpty) return value;
    final indexKey = _profileIndexKey(channelIndex);
    if (key != indexKey) {
      final legacy = prefs.getString(indexKey);
      if (legacy != null && legacy.isNotEmpty) {
        appLogger.info(
          'Migrating Cyr2Lat profile $indexKey -> $key (PSK-keyed, #1257)',
          tag: 'Storage',
        );
        await prefs.setString(key, legacy);
        await prefs.remove(indexKey);
        return legacy;
      }
    }
    return null;
  }

  Future<void> saveCyr2LatProfileId(int channelIndex, String? profileId) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save channel settings.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final psk = _psk(channelIndex, forWrite: true);
    final key = psk != null
        ? _profilePskKey(psk)
        : _profileIndexKey(channelIndex);
    final indexKey = _profileIndexKey(channelIndex);
    if (profileId == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, profileId);
    }
    if (key != indexKey) await prefs.remove(indexKey);
  }
}
