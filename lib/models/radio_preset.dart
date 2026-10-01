import 'dart:convert';

import 'radio_settings.dart';

// Regional radio presets (#647). Two sources, both published in the
// OffbandMesh/config-profiles repo under radio-presets/ (schema in its SCHEMA.md):
//  - meshcore-upstream.json: MeshCore's suggested presets (maintained by Liam
//    Cottle), mirrored unmodified; numbers arrive as strings.
//  - offband.json: Offband's overlay; numbers are JSON numbers.
// Parsing is resilient: a malformed entry is skipped and counted, never fatal,
// but a file of the wrong format or a newer format_version is rejected.

const String kUpstreamPresetFormat = 'meshcore-upstream-radio-presets';
const String kOverlayPresetFormat = 'offband-radio-presets';

/// Highest format_version this build understands, for both files.
const int kRadioPresetFormatVersion = 1;

enum RadioPresetSource { meshcore, offband }

class RadioPreset {
  const RadioPreset({
    required this.id,
    required this.title,
    required this.region,
    required this.frequencyMHz,
    required this.bandwidth,
    required this.spreadingFactor,
    required this.codingRate,
    required this.source,
    this.txPowerDbm,
    this.pathHashBytes,
    this.offGrid = false,
  });

  final String id;
  final String title;

  /// Picker group, e.g. "USA", "Australia", "Off-Grid".
  final String region;
  final double frequencyMHz;
  final LoRaBandwidth bandwidth;
  final LoRaSpreadingFactor spreadingFactor;
  final LoRaCodingRate codingRate;
  final RadioPresetSource source;

  /// Null leaves the radio's TX power alone (upstream presets never set it).
  final int? txPowerDbm;

  /// Path hash size in bytes (1-3), as published. Null leaves the radio's
  /// setting alone.
  final int? pathHashBytes;

  /// A client-repeat (off-grid) frequency rather than a regional preset.
  final bool offGrid;

  int get frequencyHz => (frequencyMHz * 1000).round();
}

class RadioPresetFormatException implements Exception {
  const RadioPresetFormatException(this.message);
  final String message;
  @override
  String toString() => 'RadioPresetFormatException: $message';
}

class RadioPresetParseResult {
  const RadioPresetParseResult(this.presets, this.skipped);
  final List<RadioPreset> presets;

  /// Malformed entries left out, so a partly bad file never looks complete.
  final int skipped;
}

/// Parse the mirrored MeshCore list (`meshcore-upstream.json`).
RadioPresetParseResult parseUpstreamPresets(String source) {
  final doc = _decodeObject(source, kUpstreamPresetFormat);
  final srs = doc['suggested_radio_settings'];
  final entries = srs is Map ? srs['entries'] : null;
  if (entries is! List) {
    throw const RadioPresetFormatException(
      'suggested_radio_settings.entries must be a list',
    );
  }
  final presets = <RadioPreset>[];
  var skipped = 0;
  for (final e in entries) {
    final preset = e is Map ? _upstreamEntry(e) : null;
    if (preset == null) {
      skipped++;
    } else {
      presets.add(preset);
    }
  }
  return RadioPresetParseResult(presets, skipped);
}

/// Parse the Offband overlay (`offband.json`). Retired entries are dropped.
RadioPresetParseResult parseOverlayPresets(String source) {
  final doc = _decodeObject(source, kOverlayPresetFormat);
  final entries = doc['presets'];
  if (entries is! List) {
    throw const RadioPresetFormatException('presets must be a list');
  }
  final presets = <RadioPreset>[];
  var skipped = 0;
  for (final e in entries) {
    if (e is Map && e['status'] == 'retired') continue;
    final preset = e is Map ? _overlayEntry(e) : null;
    if (preset == null) {
      skipped++;
    } else {
      presets.add(preset);
    }
  }
  return RadioPresetParseResult(presets, skipped);
}

Map _decodeObject(String source, String format) {
  final dynamic doc;
  try {
    doc = jsonDecode(source);
  } on FormatException catch (e) {
    throw RadioPresetFormatException('not valid JSON: ${e.message}');
  }
  if (doc is! Map) {
    throw const RadioPresetFormatException('must be a JSON object');
  }
  if (doc['format'] != format) {
    throw RadioPresetFormatException('format must be "$format"');
  }
  final version = doc['format_version'];
  if (version is! int) {
    throw const RadioPresetFormatException('format_version is required');
  }
  if (version > kRadioPresetFormatVersion) {
    throw RadioPresetFormatException(
      'format_version $version is newer than this app supports '
      '($kRadioPresetFormatVersion). Update the app.',
    );
  }
  return doc;
}

RadioPreset? _upstreamEntry(Map e) {
  final title = e['title'];
  if (title is! String || title.trim().isEmpty) return null;
  final ns = e['network_settings'];
  final hash = ns is Map ? _asInt(ns['path_hash_size']) : null;
  if (ns is Map && ns.containsKey('path_hash_size') && !_validHash(hash)) {
    return null;
  }
  return _build(
    id: 'meshcore:$title',
    title: title,
    region: upstreamRegionFor(title),
    frequency: _asDouble(e['frequency']),
    bandwidthKHz: _asDouble(e['bandwidth']),
    sf: _asInt(e['spreading_factor']),
    cr: _asInt(e['coding_rate']),
    source: RadioPresetSource.meshcore,
    pathHashBytes: hash,
  );
}

RadioPreset? _overlayEntry(Map e) {
  final id = e['id'];
  final title = e['title'];
  final region = e['region'];
  if (id is! String || id.isEmpty) return null;
  if (title is! String || title.trim().isEmpty) return null;
  if (region is! String || region.trim().isEmpty) return null;
  // The overlay is hand-edited: numbers must be JSON numbers, not strings.
  for (final key in const [
    'frequency',
    'bandwidth',
    'spreading_factor',
    'coding_rate',
  ]) {
    if (e[key] is! num) return null;
  }
  final tx = e['tx_power'];
  if (tx != null && (tx is! int || tx < -9 || tx > 30)) return null;
  final hash = e['path_hash_size'];
  if (hash != null && (hash is! int || !_validHash(hash))) return null;
  final offGrid = e['off_grid'];
  if (offGrid != null && offGrid is! bool) return null;
  return _build(
    id: 'offband:$id',
    title: title,
    region: region,
    frequency: (e['frequency'] as num).toDouble(),
    bandwidthKHz: (e['bandwidth'] as num).toDouble(),
    sf: _asInt(e['spreading_factor']),
    cr: _asInt(e['coding_rate']),
    source: RadioPresetSource.offband,
    txPowerDbm: tx as int?,
    pathHashBytes: hash as int?,
    offGrid: offGrid == true,
  );
}

RadioPreset? _build({
  required String id,
  required String title,
  required String region,
  required double? frequency,
  required double? bandwidthKHz,
  required int? sf,
  required int? cr,
  required RadioPresetSource source,
  int? txPowerDbm,
  int? pathHashBytes,
  bool offGrid = false,
}) {
  if (frequency == null || frequency < 150 || frequency > 2500) return null;
  if (bandwidthKHz == null) return null;
  final bwHz = (bandwidthKHz * 1000).round();
  final bandwidth = LoRaBandwidth.values
      .where((b) => (b.hz - bwHz).abs() <= 50)
      .firstOrNull;
  final spreading = LoRaSpreadingFactor.values
      .where((s) => s.value == sf)
      .firstOrNull;
  final coding = LoRaCodingRate.values.where((c) => c.value == cr).firstOrNull;
  if (bandwidth == null || spreading == null || coding == null) return null;
  return RadioPreset(
    id: id,
    title: title.trim(),
    region: region.trim(),
    frequencyMHz: frequency,
    bandwidth: bandwidth,
    spreadingFactor: spreading,
    codingRate: coding,
    source: source,
    txPowerDbm: txPowerDbm,
    pathHashBytes: pathHashBytes,
    offGrid: offGrid,
  );
}

bool _validHash(int? bytes) => bytes != null && bytes >= 1 && bytes <= 3;

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int? _asInt(Object? v) {
  final d = _asDouble(v);
  if (d == null || d != d.roundToDouble()) return null;
  return d.round();
}

/// The picker group for an upstream title, which carries no region field:
/// the part before " - ", ":" or " (" ("USA - Southern California" -> "USA",
/// "Australia: QLD" -> "Australia", "EU/UK (Narrow)" -> "EU/UK"), otherwise the
/// title without a trailing band number ("Portugal 433" -> "Portugal"),
/// otherwise the whole title ("Costa Rica").
String upstreamRegionFor(String title) {
  final t = title.trim();
  var cut = t.length;
  for (final sep in const [' - ', ':', ' (']) {
    final i = t.indexOf(sep);
    if (i > 0 && i < cut) cut = i;
  }
  if (cut < t.length) return t.substring(0, cut).trim();
  final band = RegExp(r'^(.+?)\s+\d+$').firstMatch(t);
  return band != null ? band.group(1)! : t;
}
