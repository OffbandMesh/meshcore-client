import '../utils/app_logger.dart';
import 'prefs_manager.dart';

class ContactSettingsStore {
  static const String _cyr2latKeyPrefix = 'contact_cyr2lat_';

  /// Per-contact custom display name, the user's own label. (#750)
  ///
  /// This lives here rather than in `contact_store` on purpose. That record is
  /// rebuilt from the radio's contact-sync data, where no custom name exists,
  /// so a save after a sync would wipe it. Keyed by pubkey hex here, a sync
  /// cannot reach it.
  static const String _customNameKeyPrefix = 'contact_customname_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String get keyForCyr2Lat => '$_cyr2latKeyPrefix$publicKeyHex';

  String get keyForCustomName => '$_customNameKeyPrefix$publicKeyHex';

  /// The user's label for [contactKeyHex], or null when they have not set one.
  Future<String?> loadCustomName(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load contact custom name.',
      );
      return null;
    }
    final prefs = PrefsManager.instance;
    return prefs.getString('$keyForCustomName$contactKeyHex');
  }

  /// Sets or clears the user's label for [contactKeyHex].
  ///
  /// Null, empty and whitespace-only all **remove** the entry rather than
  /// storing a blank. This is the second enforcement point for that rule, after
  /// `Contact.name`: a UI that passes an empty string cannot leave a contact
  /// with a blank display name and no way back. (T9d, T9e, T29, T30)
  Future<void> saveCustomName(String contactKeyHex, String? name) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save contact custom name.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final key = '$keyForCustomName$contactKeyHex';
    if (name == null || name.trim().isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, name);
    }
  }

  Future<bool> loadCyr2LatEnabled(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load contact Cyr2Lat settings.',
      );
      return false;
    }
    final prefs = PrefsManager.instance;
    final key = '$keyForCyr2Lat$contactKeyHex';
    return prefs.getBool(key) ?? false;
  }

  Future<void> saveCyr2LatEnabled(String contactKeyHex, bool enabled) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save contact Cyr2Lat settings.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final key = '$keyForCyr2Lat$contactKeyHex';
    await prefs.setBool(key, enabled);
  }

  Future<String?> loadCyr2LatProfileId(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load contact settings.',
      );
      return null;
    }
    final prefs = PrefsManager.instance;
    final key = '${keyForCyr2Lat}profile_$contactKeyHex';
    return prefs.getString(key);
  }

  Future<void> saveCyr2LatProfileId(
    String contactKeyHex,
    String? profileId,
  ) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save contact settings.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final key = '${keyForCyr2Lat}profile_$contactKeyHex';
    if (profileId == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, profileId);
    }
  }
}
