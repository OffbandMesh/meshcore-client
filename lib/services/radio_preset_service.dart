import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/radio_preset.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
import 'config_source_service.dart';

/// Where the preset files are published (OffbandMesh/config-profiles, #721).
const String kRadioPresetBaseUrl =
    'https://raw.githubusercontent.com/OffbandMesh/config-profiles/main/radio-presets/';
const String kUpstreamPresetFile = 'meshcore-upstream.json';
const String kOverlayPresetFile = 'offband.json';

/// The copies bundled with the app, so the picker works offline.
const String kRadioPresetAssetDir = 'assets/radio_presets/';

const String _prefsPrefix = 'radio_presets_v1_';
const String _prefsRefreshedKey = '${_prefsPrefix}refreshed_at';

typedef PresetTextLoader = Future<String> Function(String location);

/// The regional radio preset list (#728): MeshCore's upstream presets plus
/// Offband's overlay, merged with the overlay winning on a matching title.
///
/// Starts from the last good copy (or the bundled one), and refreshes from
/// config-profiles on demand. A file that fails to fetch or parse never
/// replaces a good copy; the failure is logged and kept in [refreshError] so
/// the picker can show it.
class RadioPresetService extends ChangeNotifier {
  RadioPresetService({
    PresetTextLoader? fetch,
    PresetTextLoader? loadAsset,
    SharedPreferences? prefs,
    DateTime Function()? clock,
  }) : _fetch = fetch,
       _loadAsset = loadAsset ?? rootBundle.loadString,
       _prefsOverride = prefs,
       _clock = clock ?? DateTime.now;

  final PresetTextLoader? _fetch;
  final PresetTextLoader _loadAsset;
  final SharedPreferences? _prefsOverride;
  final DateTime Function() _clock;
  ConfigSourceService? _source;

  SharedPreferences get _prefs => _prefsOverride ?? PrefsManager.instance;

  RadioPresetParseResult _upstream = const RadioPresetParseResult([], 0);
  RadioPresetParseResult _overlay = const RadioPresetParseResult([], 0);
  List<RadioPreset> _presets = const [];
  String? _refreshError;
  DateTime? _lastRefreshed;
  bool _refreshing = false;

  List<RadioPreset> get presets => _presets;

  /// Entries left out of the files in use because they were malformed.
  int get skipped => _upstream.skipped + _overlay.skipped;

  /// Why the last refresh (or load) failed, or null when it succeeded.
  String? get refreshError => _refreshError;
  DateTime? get lastRefreshed => _lastRefreshed;
  bool get refreshing => _refreshing;

  /// Load the last good copy of each file, falling back to the bundled one.
  Future<void> load() async {
    final errors = <String>[];
    _upstream = await _loadLocal(
      kUpstreamPresetFile,
      parseUpstreamPresets,
      errors,
    );
    _overlay = await _loadLocal(
      kOverlayPresetFile,
      parseOverlayPresets,
      errors,
    );
    final stamp = _prefs.getString(_prefsRefreshedKey);
    _lastRefreshed = stamp == null ? null : DateTime.tryParse(stamp);
    _refreshError = errors.isEmpty ? null : errors.join('; ');
    _rebuild();
  }

  /// Refresh when the copy in use is older than [maxAge] or was never
  /// refreshed. Returns whether a refresh ran and succeeded.
  Future<bool> refreshIfStale({
    Duration maxAge = const Duration(hours: 12),
  }) async {
    final last = _lastRefreshed;
    if (last != null && _clock().difference(last) < maxAge) return false;
    return refresh();
  }

  /// Fetch both files from config-profiles. Each file that parses replaces
  /// its copy and is saved as the new last good copy; each that fails keeps
  /// the copy in use. Returns true only when both succeeded.
  Future<bool> refresh() async {
    if (_refreshing) return false;
    _refreshing = true;
    notifyListeners();
    final errors = <String>[];
    final upstream = await _fetchRemote(
      kUpstreamPresetFile,
      parseUpstreamPresets,
      errors,
    );
    final overlay = await _fetchRemote(
      kOverlayPresetFile,
      parseOverlayPresets,
      errors,
    );
    if (upstream != null) _upstream = upstream;
    if (overlay != null) _overlay = overlay;
    if (errors.isEmpty) {
      _lastRefreshed = _clock();
      await _prefs.setString(
        _prefsRefreshedKey,
        _lastRefreshed!.toIso8601String(),
      );
      _refreshError = null;
    } else {
      _refreshError = errors.join('; ');
    }
    _refreshing = false;
    _rebuild();
    return errors.isEmpty;
  }

  Future<RadioPresetParseResult> _loadLocal(
    String file,
    RadioPresetParseResult Function(String) parse,
    List<String> errors,
  ) async {
    final cached = _prefs.getString('$_prefsPrefix$file');
    if (cached != null) {
      try {
        return parse(cached);
      } catch (e) {
        appLogger.warn(
          'Saved copy of $file unusable, using the bundled one: $e',
          tag: 'RadioPresets',
        );
      }
    }
    try {
      return parse(await _loadAsset('$kRadioPresetAssetDir$file'));
    } catch (e) {
      appLogger.error('Bundled $file failed to load: $e', tag: 'RadioPresets');
      errors.add('$file: $e');
      return const RadioPresetParseResult([], 0);
    }
  }

  Future<RadioPresetParseResult?> _fetchRemote(
    String file,
    RadioPresetParseResult Function(String) parse,
    List<String> errors,
  ) async {
    final url = '$kRadioPresetBaseUrl$file';
    try {
      final text = _fetch != null
          ? await _fetch(url)
          : await (_source ??= ConfigSourceService()).fetchText(url);
      final parsed = parse(text);
      if (parsed.presets.isEmpty) {
        throw RadioPresetFormatException('$file has no usable presets');
      }
      await _prefs.setString('$_prefsPrefix$file', text);
      if (parsed.skipped > 0) {
        appLogger.warn(
          '$file: ${parsed.skipped} malformed preset(s) skipped',
          tag: 'RadioPresets',
        );
      }
      return parsed;
    } catch (e) {
      appLogger.warn('Refreshing $file failed: $e', tag: 'RadioPresets');
      errors.add('$file: $e');
      return null;
    }
  }

  void _rebuild() {
    _presets = mergeRadioPresets(_upstream.presets, _overlay.presets);
    notifyListeners();
  }

  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }
}

/// Upstream presets plus the overlay. An overlay entry whose title matches an
/// upstream one (ignoring case) replaces it. Sorted by region, then title.
List<RadioPreset> mergeRadioPresets(
  List<RadioPreset> upstream,
  List<RadioPreset> overlay,
) {
  final byTitle = <String, RadioPreset>{
    for (final p in upstream) p.title.toLowerCase(): p,
  };
  for (final p in overlay) {
    byTitle[p.title.toLowerCase()] = p;
  }
  final merged = byTitle.values.toList()
    ..sort((a, b) {
      final r = a.region.toLowerCase().compareTo(b.region.toLowerCase());
      return r != 0
          ? r
          : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  return merged;
}
