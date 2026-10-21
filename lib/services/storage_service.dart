import 'dart:convert';
import '../models/delivery_observation.dart';
import '../models/path_history.dart';
import '../storage/drift/blob_store.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';

class StorageService {
  static const String _pathHistoryPrefix = 'path_history_';
  static const String _repeaterPasswordsKey = 'repeater_passwords';
  static const String _repeaterAutoClockSyncAfterLoginKey =
      'repeater_auto_clock_sync_after_login';
  static const String _deliveryObservationsKey = 'delivery_observations';

  Future<Map<String, bool>> _loadRepeaterAutoClockSyncAfterLogin() async {
    final prefs = PrefsManager.instance;
    final jsonStr = prefs.getString(_repeaterAutoClockSyncAfterLoginKey);

    if (jsonStr == null) return {};

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return json.map((key, value) => MapEntry(key, value == true));
    } catch (e) {
      return {};
    }
  }

  Future<bool> getRepeaterAutoClockSyncAfterLoginEnabled(
    String repeaterPubKeyHex,
  ) async {
    final settings = await _loadRepeaterAutoClockSyncAfterLogin();
    return settings[repeaterPubKeyHex] ?? false;
  }

  Future<void> setRepeaterAutoClockSyncAfterLoginEnabled(
    String repeaterPubKeyHex,
    bool enabled,
  ) async {
    final prefs = PrefsManager.instance;
    final settings = await _loadRepeaterAutoClockSyncAfterLogin();
    settings[repeaterPubKeyHex] = enabled;
    final jsonStr = jsonEncode(settings);
    await prefs.setString(_repeaterAutoClockSyncAfterLoginKey, jsonStr);
  }

  /// First 10 hex of the connected radio's public key, like every per-radio
  /// store. Set on connect.
  ///
  /// Path history is what THIS radio learned about reaching a contact. Keyed
  /// by contact alone (the pre-#854 scheme) a route measured by a 1 W handheld
  /// was applied to a repeater, and the reverse.
  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String _pathKey(String contactPubKeyHex) =>
      '$_pathHistoryPrefix$publicKeyHex$contactPubKeyHex';

  /// Per-radio, and in drift rather than SharedPreferences (#854, #924).
  ///
  /// Two changes in one migration, because doing them separately would mean
  /// two migrations over the same data. Prefs is a settings store: on Windows
  /// every write re-encodes and rewrites the whole file, and this one store
  /// held 2,092 keys and 86% of a 4.28 MB file, which made every unrelated
  /// settings write cost ~32 ms (#923).
  ///
  /// With no radio key set this loads nothing and never writes, so it cannot
  /// read or clobber anything. That is the #754 precedent.
  Future<void> savePathHistory(
    String contactPubKeyHex,
    ContactPathHistory history,
  ) async {
    if (publicKeyHex.isEmpty) return;
    await BlobStore.instance.write(
      _pathKey(contactPubKeyHex),
      jsonEncode(history.toJson()),
    );
  }

  Future<ContactPathHistory?> loadPathHistory(String contactPubKeyHex) async {
    if (publicKeyHex.isEmpty) return null;
    final jsonStr = await BlobStore.instance.read(_pathKey(contactPubKeyHex));
    if (jsonStr == null || jsonStr.isEmpty) return null;

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return ContactPathHistory.fromJson(contactPubKeyHex, json);
    } catch (e) {
      appLogger.error(
        'Failed to decode path history for $contactPubKeyHex: $e',
        tag: 'Storage',
      );
      return null;
    }
  }

  Future<void> clearPathHistory(String contactPubKeyHex) async {
    if (publicKeyHex.isEmpty) return;
    await BlobStore.instance.delete(_pathKey(contactPubKeyHex));
  }

  /// Clears this radio's path history only. Another radio's routes are not
  /// touched, which they were before #854 because the key had no radio in it.
  Future<void> clearAllPathHistories() async {
    if (publicKeyHex.isEmpty) return;
    final mine = '$_pathHistoryPrefix$publicKeyHex';
    for (final key in await BlobStore.instance.keysWithPrefix(mine)) {
      await BlobStore.instance.delete(key);
    }
  }

  /// Removes the pre-#854 untagged `path_history_<contact>` keys from
  /// SharedPreferences, a chunk at a time, yielding between chunks.
  ///
  /// These cannot be migrated: the key records which CONTACT a route reaches
  /// and never which radio measured it, so attributing them to a radio would
  /// be a guess. The owner's decision (plan §9, decision 1) is to delete them
  /// rather than orphan them, because routes relearn in normal use and here
  /// the orphaned data is itself the performance problem.
  ///
  /// Chunked because each `remove` re-encodes and rewrites the whole prefs
  /// file. Measured against the owner's real file: 2,092 keys, **12.7 s of
  /// total work**, mean 6.1 ms, but 32 ms for the first removal and under
  /// 1 ms by the last, because the file collapses from 4.28 MB to 45 KB as it
  /// goes. One unbroken pass would block for 12.7 s, well past the 5 s
  /// watchdog, which is the very failure #917 just fixed. [chunkSize] keeps
  /// any single block near 20 removals' worth and the yield lets the UI
  /// breathe between them.
  ///
  /// Returns how many keys it removed. Safe to call repeatedly: when there is
  /// nothing left it does no writes at all.
  Future<int> purgeLegacyPathHistory({int chunkSize = 20}) async {
    final prefs = PrefsManager.instance;
    // A legacy key is one in PREFS. The new scheme writes to drift, so the
    // two backends cannot be confused and no length or shape heuristic is
    // needed to tell them apart.
    final legacy = prefs
        .getKeys()
        .where((k) => k.startsWith(_pathHistoryPrefix))
        .toList();
    if (legacy.isEmpty) return 0;

    appLogger.info(
      'Purging ${legacy.length} pre-#854 untagged path_history keys from '
      'prefs, $chunkSize at a time. These record which contact a route '
      'reaches and never which radio measured it, so they cannot be '
      'attributed; routes relearn in normal use (#854, plan decision 1).',
      tag: 'Storage',
    );

    var removed = 0;
    for (var i = 0; i < legacy.length; i++) {
      await prefs.remove(legacy[i]);
      removed++;
      if ((i + 1) % chunkSize == 0) {
        // Let the UI isolate run. Without this the whole purge is one block.
        await Future<void>.delayed(Duration.zero);
      }
    }

    appLogger.info(
      'Purged $removed legacy path_history keys. Every remaining prefs write '
      'is now cheaper in proportion (#923).',
      tag: 'Storage',
    );
    return removed;
  }

  /// Save a repeater password by public key hex
  Future<void> saveRepeaterPassword(
    String repeaterPubKeyHex,
    String password,
  ) async {
    final prefs = PrefsManager.instance;
    final passwords = await loadRepeaterPasswords();
    passwords[repeaterPubKeyHex] = password;
    final jsonStr = jsonEncode(passwords);
    await prefs.setString(_repeaterPasswordsKey, jsonStr);
  }

  /// Load all saved repeater passwords (map of pubKeyHex -> password)
  Future<Map<String, String>> loadRepeaterPasswords() async {
    final prefs = PrefsManager.instance;
    final jsonStr = prefs.getString(_repeaterPasswordsKey);

    if (jsonStr == null) return {};

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      return json.map((key, value) => MapEntry(key, value as String));
    } catch (e) {
      return {};
    }
  }

  /// Get a specific repeater's saved password
  Future<String?> getRepeaterPassword(String repeaterPubKeyHex) async {
    final passwords = await loadRepeaterPasswords();
    return passwords[repeaterPubKeyHex];
  }

  /// Remove a saved repeater password
  Future<void> removeRepeaterPassword(String repeaterPubKeyHex) async {
    final prefs = PrefsManager.instance;
    final passwords = await loadRepeaterPasswords();
    passwords.remove(repeaterPubKeyHex);
    final jsonStr = jsonEncode(passwords);
    await prefs.setString(_repeaterPasswordsKey, jsonStr);
  }

  /// Clear all saved repeater passwords
  Future<void> clearAllRepeaterPasswords() async {
    final prefs = PrefsManager.instance;
    await prefs.remove(_repeaterPasswordsKey);
  }

  String get _observationsKey => '$_deliveryObservationsKey$publicKeyHex';

  /// Per-radio (#856).
  ///
  /// These feed the ACK-timeout prediction model. On one global key, a
  /// repeater's 45-second deliveries trained the model a 1 W handheld then
  /// used, and the reverse. Silent accuracy loss rather than a visible
  /// failure, which is why nobody reported it.
  ///
  /// Stays in SharedPreferences, unlike path history: this is one small key
  /// (3,091 bytes and 14 entries on the owner's install), not 2,092 keys and
  /// 86% of the file, so there is no cost argument for moving it and a move
  /// would be churn.
  Future<void> saveDeliveryObservations(
    List<DeliveryObservation> observations,
  ) async {
    if (publicKeyHex.isEmpty) return;
    final prefs = PrefsManager.instance;
    final jsonStr = jsonEncode(observations.map((o) => o.toJson()).toList());
    await prefs.setString(_observationsKey, jsonStr);
  }

  Future<List<DeliveryObservation>> loadDeliveryObservations() async {
    if (publicKeyHex.isEmpty) return [];
    final prefs = PrefsManager.instance;
    final jsonStr = prefs.getString(_observationsKey);

    if (jsonStr == null) return [];

    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => DeliveryObservation.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      appLogger.error(
        'Failed to decode delivery observations: $e',
        tag: 'Storage',
      );
      return [];
    }
  }

  Future<void> clearDeliveryObservations() async {
    if (publicKeyHex.isEmpty) return;
    await PrefsManager.instance.remove(_observationsKey);
  }

  /// Removes the pre-#856 untagged global observation list.
  ///
  /// One key, so no chunking is needed. Deleted rather than attributed to a
  /// radio (plan §9, decision 1): it is a mixture of every radio's RF timing,
  /// and mixed data is worse than no data for the model, which retrains from
  /// live sends within normal use.
  ///
  /// Returns true if there was one to remove.
  Future<bool> purgeLegacyDeliveryObservations() async {
    final prefs = PrefsManager.instance;
    if (!prefs.containsKey(_deliveryObservationsKey)) return false;
    await prefs.remove(_deliveryObservationsKey);
    appLogger.info(
      'Purged the pre-#856 global delivery-observation list. It mixed every '
      'radio\'s RF timing, so it is deleted rather than attributed; the '
      'model retrains per radio from live sends (#856).',
      tag: 'Storage',
    );
    return true;
  }
}
