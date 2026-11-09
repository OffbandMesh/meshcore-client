import 'dart:convert';
import 'dart:io';

/// A firmware protocol manifest (#769): the codes, capability bits and version
/// a firmware build defines, generated from its source. Today's copies are
/// pinned under `manifests/` by `tool/fake_radio/gen_protocol_manifest.py`;
/// OffbandMesh/meshcore-firmware#1318 will publish them from firmware CI.
class FakeRadioManifest {
  FakeRadioManifest._(this.json);

  factory FakeRadioManifest.parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['format'] != 'offband-protocol-manifest') {
      throw FormatException('not a protocol manifest: ${json['format']}');
    }
    if (json['format_version'] != 1) {
      throw FormatException(
        'unsupported manifest format_version ${json['format_version']}',
      );
    }
    return FakeRadioManifest._(json);
  }

  factory FakeRadioManifest.load(String path) =>
      FakeRadioManifest.parse(File(path).readAsStringSync());

  static const String _dir = 'test/support/fake_radio/manifests';

  /// The Offband release the fake's Offband profile is pinned to.
  static FakeRadioManifest pinnedOffband() =>
      FakeRadioManifest.load('$_dir/offband-v1.5.0-beta7.json');

  /// The upstream MeshCore release the fake's stock profile is pinned to.
  static FakeRadioManifest pinnedStock() =>
      FakeRadioManifest.load('$_dir/stock-companion-v1.17.1.json');

  final Map<String, dynamic> json;

  Map<String, dynamic> get _firmware =>
      json['firmware'] as Map<String, dynamic>;

  String get flavor => _firmware['flavor'] as String;
  bool get isOffband => flavor == 'offband';
  String get ref => _firmware['ref'] as String;
  String get commit => _firmware['commit'] as String;

  /// `FIRMWARE_VERSION`, the MeshCore base, e.g. `v1.17.0`.
  String get firmwareVersion => _firmware['firmware_version'] as String;
  int get firmwareVerCode => _firmware['firmware_ver_code'] as int;

  Map<String, int> section(String name) =>
      (json[name] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as int));

  Map<String, int> get commands => section('commands');
  Map<String, int> get responses => section('responses');
  Map<String, int> get pushes => section('pushes');
  Map<String, int> get errors => section('errors');
  Map<String, int> get offbandCommands => section('offband_commands');
  Map<String, int> get offbandResponses => section('offband_responses');
  Map<String, int> get offbandCaps => section('offband_caps');
  Map<String, int> get offbandCaps2 => section('offband_caps2');

  /// OR of the named capability bits; throws if the manifest lacks one, so a
  /// renamed or removed bit fails loudly instead of reading as 0.
  int capsOf(Iterable<String> names, {bool second = false}) {
    final table = second ? offbandCaps2 : offbandCaps;
    var bits = 0;
    for (final n in names) {
      final v = table[n];
      if (v == null) throw StateError('$ref defines no $n');
      bits |= v;
    }
    return bits;
  }

  /// The 20-byte DEVICE_INFO version field this build reports.
  ///
  /// Offband: `offbandClientVersion()` (MyMesh.cpp:1761), the Offband core,
  /// a '-', then the MeshCore core (e.g. `1.5.0-1.17.0`); each core is cut at
  /// its first '-', with the 'v' stripped from the MeshCore one. Stock:
  /// `FIRMWARE_VERSION` as is.
  String get deviceInfoVersion {
    if (!isOffband) return firmwareVersion;
    var mc = firmwareVersion;
    if (mc.startsWith('v') || mc.startsWith('V')) mc = mc.substring(1);
    mc = mc.split('-').first;
    final at = ref.indexOf('offband-v');
    if (at < 0) return mc;
    final ob = ref.substring(at + 'offband-v'.length).split('-').first;
    return ob.isEmpty ? mc : '$ob-$mc';
  }
}
