import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/app_settings.dart';
import '../models/translation_support.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import '../helpers/cyr2lat.dart';

class AppSettingsService extends ChangeNotifier {
  static const String _settingsKey = 'app_settings';

  AppSettings _settings = AppSettings();

  AppSettings get settings => _settings;

  String batteryChemistryForDevice(String deviceId) {
    final stored = _settings.batteryChemistryByDeviceId[deviceId];
    if (stored == 'liion') return 'nmc';
    return stored ?? 'nmc';
  }

  String batteryChemistryForRepeater(String repeaterPubKeyHex) {
    final stored = _settings.batteryChemistryByRepeaterId[repeaterPubKeyHex];
    if (stored == 'liion') return 'nmc';
    return stored ?? 'nmc';
  }

  Future<void> loadSettings() async {
    final prefs = PrefsManager.instance;
    final jsonStr = prefs.getString(_settingsKey);

    if (jsonStr != null) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        _settings = AppSettings.fromJson(json);
        Cyr2Lat.setCharMap(_settings.cyr2latCharMap);
        notifyListeners();
      } catch (e) {
        // If parsing fails, use defaults
        _settings = AppSettings();
        Cyr2Lat.setCharMap(_settings.cyr2latCharMap);
      }
    } else {
      _settings = AppSettings();
      Cyr2Lat.setCharMap(_settings.cyr2latCharMap);
    }
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    _settings = newSettings;
    Cyr2Lat.setCharMap(_settings.cyr2latCharMap);
    notifyListeners();

    final prefs = PrefsManager.instance;
    final jsonStr = jsonEncode(_settings.toJson());
    await prefs.setString(_settingsKey, jsonStr);
  }

  Future<void> setClearPathOnMaxRetry(bool value) async {
    await updateSettings(_settings.copyWith(clearPathOnMaxRetry: value));
  }

  Future<void> setMapShowRepeaters(bool value) async {
    await updateSettings(_settings.copyWith(mapShowRepeaters: value));
  }

  Future<void> setMapShowChatNodes(bool value) async {
    await updateSettings(_settings.copyWith(mapShowChatNodes: value));
  }

  Future<void> setMapShowOtherNodes(bool value) async {
    await updateSettings(_settings.copyWith(mapShowOtherNodes: value));
  }

  Future<void> setMapShowOverlaps(bool value) async {
    await updateSettings(_settings.copyWith(mapShowOverlaps: value));
  }

  Future<void> setMapAlwaysShowNames(bool value) async {
    await updateSettings(_settings.copyWith(mapAlwaysShowNames: value));
  }

  Future<void> setMapTimeFilterHours(double value) async {
    await updateSettings(_settings.copyWith(mapTimeFilterHours: value));
  }

  Future<void> setMapKeyPrefixEnabled(bool value) async {
    await updateSettings(_settings.copyWith(mapKeyPrefixEnabled: value));
  }

  Future<void> setMapKeyPrefix(String value) async {
    await updateSettings(_settings.copyWith(mapKeyPrefix: value));
  }

  Future<void> setMapShowMarkers(bool value) async {
    await updateSettings(_settings.copyWith(mapShowMarkers: value));
  }

  Future<void> setMapShowGuessedLocations(bool value) async {
    await updateSettings(_settings.copyWith(mapShowGuessedLocations: value));
  }

  Future<void> setEnableMessageTracing(bool value) async {
    await updateSettings(_settings.copyWith(enableMessageTracing: value));
  }

  Future<void> setKeepScreenAwake(bool value) async {
    await updateSettings(_settings.copyWith(keepScreenAwake: value));
  }

  Future<void> setClockFormat(ClockFormat value) async {
    await updateSettings(_settings.copyWith(clockFormat: value));
  }

  Future<void> setMapCacheBounds(Map<String, double>? value) async {
    await updateSettings(_settings.copyWith(mapCacheBounds: value));
  }

  Future<void> setMapCacheZoomRange(int minZoom, int maxZoom) async {
    final safeMin = minZoom <= maxZoom ? minZoom : maxZoom;
    final safeMax = minZoom <= maxZoom ? maxZoom : minZoom;
    await updateSettings(
      _settings.copyWith(mapCacheMinZoom: safeMin, mapCacheMaxZoom: safeMax),
    );
  }

  Future<void> setNotificationsEnabled(bool value) async {
    await updateSettings(_settings.copyWith(notificationsEnabled: value));
  }

  Future<void> setNotifyOnNewMessage(bool value) async {
    await updateSettings(_settings.copyWith(notifyOnNewMessage: value));
  }

  Future<void> setNotifyOnNewChannelMessage(bool value) async {
    await updateSettings(_settings.copyWith(notifyOnNewChannelMessage: value));
  }

  Future<void> setNotifyOnNewAdvert(bool value) async {
    await updateSettings(_settings.copyWith(notifyOnNewAdvert: value));
  }

  Future<void> setAutoRouteRotationEnabled(bool value) async {
    await updateSettings(_settings.copyWith(autoRouteRotationEnabled: value));
  }

  Future<void> setMaxRouteWeight(double value) async {
    await updateSettings(_settings.copyWith(maxRouteWeight: value));
  }

  Future<void> setInitialRouteWeight(double value) async {
    await updateSettings(_settings.copyWith(initialRouteWeight: value));
  }

  Future<void> setRouteWeightSuccessIncrement(double value) async {
    await updateSettings(
      _settings.copyWith(routeWeightSuccessIncrement: value),
    );
  }

  Future<void> setRouteWeightFailureDecrement(double value) async {
    await updateSettings(
      _settings.copyWith(routeWeightFailureDecrement: value),
    );
  }

  Future<void> setMaxMessageRetries(int value) async {
    await updateSettings(_settings.copyWith(maxMessageRetries: value));
  }

  Future<void> setThemeMode(String value) async {
    await updateSettings(_settings.copyWith(themeMode: value));
  }

  Future<void> setLanguageOverride(String? value) async {
    await updateSettings(_settings.copyWith(languageOverride: value));
  }

  Future<void> setAppDebugLogEnabled(bool value) async {
    await updateSettings(_settings.copyWith(appDebugLogEnabled: value));
    // Update the global logger
    appLogger.setEnabled(value);
  }

  Future<void> setExperimentalUnlocked(bool value) async {
    await updateSettings(_settings.copyWith(experimentalUnlocked: value));
  }

  Future<void> setCoreScopeObserverCountEnabled(bool value) async {
    await updateSettings(
      _settings.copyWith(coreScopeObserverCountEnabled: value),
    );
  }

  /// Turn off every experimental feature flag and re-lock the section (#553).
  /// Add each new experimental toggle here so "Disable" truly disables all.
  Future<void> disableExperimental() async {
    await updateSettings(
      _settings.copyWith(
        coreScopeObserverCountEnabled: false,
        experimentalUnlocked: false,
      ),
    );
  }

  Future<void> setMapShowDiscoveryContacts(bool value) async {
    await updateSettings(_settings.copyWith(mapShowDiscoveryContacts: value));
  }

  Future<void> setBatteryChemistryForDevice(
    String deviceId,
    String chemistry,
  ) async {
    final updated = Map<String, String>.from(
      _settings.batteryChemistryByDeviceId,
    );
    updated[deviceId] = chemistry;
    await updateSettings(
      _settings.copyWith(batteryChemistryByDeviceId: updated),
    );
  }

  Future<void> setBatteryChemistryForRepeater(
    String repeaterPubKeyHex,
    String chemistry,
  ) async {
    final updated = Map<String, String>.from(
      _settings.batteryChemistryByRepeaterId,
    );
    updated[repeaterPubKeyHex] = chemistry;
    await updateSettings(
      _settings.copyWith(batteryChemistryByRepeaterId: updated),
    );
  }

  Future<void> setUnitSystem(UnitSystem value) async {
    await updateSettings(_settings.copyWith(unitSystem: value));
  }

  /// First 10 hex of the connected radio's key, matching every other per-radio
  /// store. Empty when no radio is connected -> the caller gets the default.
  static String _scopePrefix(String devicePrefix) =>
      devicePrefix.length > 10 ? devicePrefix.substring(0, 10) : devicePrefix;

  /// Resolve a channel's notify mode for the CONNECTED radio ([devicePrefix])
  /// by its [pskHex]. No bare-index fallback and no cross-radio legacy fallback:
  /// an unknown scope (no radio, or PSK not yet synced) resolves to the default
  /// `all` rather than inheriting another radio's or slot's state (#839).
  ChannelNotifyMode channelNotifyMode({
    required String devicePrefix,
    required String? pskHex,
  }) {
    final prefix = _scopePrefix(devicePrefix);
    if (prefix.isEmpty || pskHex == null || pskHex.isEmpty) {
      return ChannelNotifyMode.all;
    }
    return _settings.channelNotifyModesByRadio[prefix]?[pskHex] ??
        ChannelNotifyMode.all;
  }

  /// Store a channel's notify mode for the connected radio. Keyed only by
  /// ([devicePrefix], [pskHex]); when either is unknown this is a no-op so we
  /// never write an unscoped or index-keyed entry. `all` removes the single
  /// entry (it is the default), so set-and-back genuinely resets (#839).
  Future<void> setChannelNotifyMode({
    required String devicePrefix,
    required String? pskHex,
    required String channelName,
    required ChannelNotifyMode mode,
  }) async {
    final prefix = _scopePrefix(devicePrefix);
    if (prefix.isEmpty || pskHex == null || pskHex.isEmpty) return;

    final byRadio = _copyByRadio();
    final radioModes = byRadio.putIfAbsent(prefix, () => {});
    if (mode == ChannelNotifyMode.all) {
      radioModes.remove(pskHex);
      if (radioModes.isEmpty) byRadio.remove(prefix);
    } else {
      radioModes[pskHex] = mode;
    }

    // Keep the legacy name-keyed set written (rollback compat only; it is not
    // consulted by the resolution above). Remove after one release.
    final muted = Set<String>.from(_settings.mutedChannels);
    if (mode == ChannelNotifyMode.off) {
      muted.add(channelName);
    } else {
      muted.remove(channelName);
    }

    await updateSettings(
      _settings.copyWith(
        channelNotifyModesByRadio: byRadio,
        mutedChannels: muted,
      ),
    );
  }

  /// One-time migration of the pre-#839 global state into the FIRST radio seen
  /// after upgrade. Called by the connector once that radio's channels are
  /// known. Later radios start clean, so the ambiguous legacy state never
  /// bleeds across radios. [pskByChannelIndex] / [pskByChannelName] resolve the
  /// legacy index- and name-keyed entries to a PSK; unresolvable ones drop.
  Future<void> migrateLegacyChannelNotify({
    required String devicePrefix,
    required Map<int, String> pskByChannelIndex,
    required Map<String, String> pskByChannelName,
  }) async {
    if (_settings.channelNotifyMigrated) return;
    final prefix = _scopePrefix(devicePrefix);
    if (prefix.isEmpty) return;

    final byRadio = _copyByRadio();
    final radioModes = byRadio.putIfAbsent(prefix, () => {});

    // 1) psk_<hex> entries map straight across; 2) <index> entries resolve via
    // the connected radio's channel table (index entries that don't resolve are
    // ambiguous and dropped); later writes override earlier.
    _settings.channelNotifyModes.forEach((key, mode) {
      if (mode == ChannelNotifyMode.all) return;
      if (key.startsWith('psk_')) {
        radioModes[key.substring(4)] = mode;
      } else {
        final idx = int.tryParse(key);
        final psk = idx == null ? null : pskByChannelIndex[idx];
        if (psk != null && psk.isNotEmpty) radioModes[psk] = mode;
      }
    });

    // 3) legacy name-keyed mutes become Off on their resolved PSK.
    for (final name in _settings.mutedChannels) {
      final psk = pskByChannelName[name];
      if (psk != null && psk.isNotEmpty) {
        radioModes[psk] = ChannelNotifyMode.off;
      }
    }

    if (radioModes.isEmpty) byRadio.remove(prefix);

    await updateSettings(
      _settings.copyWith(
        channelNotifyModesByRadio: byRadio,
        channelNotifyMigrated: true,
      ),
    );
  }

  Map<String, Map<String, ChannelNotifyMode>> _copyByRadio() => {
    for (final e in _settings.channelNotifyModesByRadio.entries)
      e.key: Map<String, ChannelNotifyMode>.from(e.value),
  };

  Future<void> setTcpServerAddress(String value) async {
    await updateSettings(_settings.copyWith(tcpServerAddress: value));
  }

  Future<void> setTcpServerPort(int value) async {
    await updateSettings(_settings.copyWith(tcpServerPort: value));
  }

  Future<void> setJumpToOldestUnread(bool value) async {
    await updateSettings(_settings.copyWith(jumpToOldestUnread: value));
  }

  Future<void> setTranslationEnabled(bool value) async {
    await updateSettings(_settings.copyWith(translationEnabled: value));
  }

  Future<void> setAutoTranslateIncomingMessages(bool value) async {
    await updateSettings(
      _settings.copyWith(autoTranslateIncomingMessages: value),
    );
  }

  Future<void> setTranslationTargetLanguageCode(String? value) async {
    await updateSettings(
      _settings.copyWith(translationTargetLanguageCode: value),
    );
  }

  Future<void> setComposerTranslationEnabled(bool value) async {
    await updateSettings(_settings.copyWith(composerTranslationEnabled: value));
  }

  Future<void> setTranslationModelSourceUrl(String? value) async {
    await updateSettings(_settings.copyWith(translationModelSourceUrl: value));
  }

  Future<void> setTranslationSelectedModelId(String? value) async {
    await updateSettings(_settings.copyWith(translationSelectedModelId: value));
  }

  Future<void> setTranslationDownloadedModels(
    List<TranslationModelRecord> value,
  ) async {
    await updateSettings(
      _settings.copyWith(translationDownloadedModels: value),
    );
  }

  Cyr2LatProfile getSelectedCyr2LatProfile() {
    return _settings.cyr2latProfiles.firstWhere(
      (p) => p.id == _settings.selectedCyr2latProfileId,
      orElse: () => _settings.cyr2latProfiles.first,
    );
  }

  Cyr2LatProfile? getCyr2LatProfileById(String profileId) {
    return _settings.cyr2latProfiles.cast<Cyr2LatProfile?>().firstWhere(
      (p) => p?.id == profileId,
      orElse: () => null,
    );
  }

  Future<void> setSelectedCyr2LatProfile(String profileId) async {
    await updateSettings(
      _settings.copyWith(selectedCyr2latProfileId: profileId),
    );
  }

  Future<void> addCyr2LatProfile(Cyr2LatProfile profile) async {
    final updated = List<Cyr2LatProfile>.from(_settings.cyr2latProfiles)
      ..add(profile);
    await updateSettings(_settings.copyWith(cyr2latProfiles: updated));
  }

  Future<void> updateCyr2LatProfile(Cyr2LatProfile updatedProfile) async {
    final updated = _settings.cyr2latProfiles
        .map((p) => p.id == updatedProfile.id ? updatedProfile : p)
        .toList();
    await updateSettings(_settings.copyWith(cyr2latProfiles: updated));
  }

  Future<void> removeCyr2LatProfile(String profileId) async {
    if (_settings.cyr2latProfiles.length <= 1) {
      return; // Don't remove the last profile
    }
    final updated = _settings.cyr2latProfiles
        .where((p) => p.id != profileId)
        .toList();
    var newSelectedId = _settings.selectedCyr2latProfileId;
    if (newSelectedId == profileId) {
      newSelectedId = updated.first.id;
    }
    await updateSettings(
      _settings.copyWith(
        cyr2latProfiles: updated,
        selectedCyr2latProfileId: newSelectedId,
      ),
    );
  }
}
