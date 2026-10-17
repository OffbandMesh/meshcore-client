// Population classifier for the connected radio (initiative #860, F1 #862).
//
// Upstream MeshCore 1.18.0 moved FIRMWARE_VER_CODE into the range the Offband
// fork had already spent (stock 14 = "CLI frame 66 exists" vs fork 14..22 =
// 0xC0-era contract numbers), so a bare `firmwareVerCode >= N` comparison no
// longer means one thing. Every capability decision routes through this
// classifier instead of reading ver code or frame offsets directly.
//
// Interim signal (plan E1.1): the device-info reply's SHAPE. Stock ships
// exactly 82 bytes; the fork appends offband_caps at offset 82 and caps
// byte 2 at offset 84 [verified against companion-v1.18.0 and firmware-base,
// INVESTIGATION.md §A/§B3]. The firmware's durable marker (decision D1)
// replaces this at one seam — see classifyDevicePopulation's doc.

import 'dart:typed_data';

/// Which firmware family the connected radio belongs to, as far as wire
/// behavior is concerned.
enum DevicePopulation {
  /// Stock MeshCore below ver 14, or anything this classifier cannot place:
  /// the fail-closed default. No fork frames, no CLI frame.
  stockLegacy,

  /// Stock MeshCore ver 14+ (1.18.0 era): CLI frame 66/29 exists; fork
  /// frames (0xC0..0xC6) and caps bytes do not.
  stockModern,

  /// Offband fork: caps byte(s) present; fork frames are gated by the
  /// advertised cap bits as before. No CLI frame until the fork absorbs
  /// upstream 1.18 (post-absorb devices flip [Classification.allowsCliFrame]
  /// at the D1 seam, not here).
  offband,
}

/// The classifier's verdict plus the coarse capability doors it opens.
/// Fine-grained gating (which 0xC command, which cap bit) stays where it is
/// today; these booleans only say which FAMILIES of frames may be emitted.
class Classification {
  const Classification({
    required this.population,
    required this.conflict,
    required this.evidence,
  });

  final DevicePopulation population;

  /// True when the signals contradicted each other (for example a fork-length
  /// frame carrying a stock version string). Conflicts classify as
  /// [DevicePopulation.stockLegacy] — fail closed — and [evidence] says why.
  final bool conflict;

  /// Human-readable signal summary for logs; never parsed.
  final String evidence;

  /// Fork frames (0xC0..0xC6) may be emitted, subject to the existing
  /// cap-bit gates.
  bool get allowsOffbandFrames => population == DevicePopulation.offband;

  /// CMD_RUN_CLI_COMMAND (66) may be emitted. Deliberately false for
  /// [DevicePopulation.offband] on the current fork base; the absorb flips
  /// this at the D1 seam together with the durable marker.
  bool get allowsCliFrame => population == DevicePopulation.stockModern;
}

/// Stock device-info replies are exactly this long; the first fork byte
/// (offband_caps) sits at this offset. [verified: CMD_DEVICE_QUERY reply
/// construction at companion-v1.18.0 — 82 bytes, unchanged from 1.17.x]
const int stockDeviceInfoLength = 82;

/// Upstream ver code that introduces the CLI frame (66/29).
const int stockCliMinVerCode = 14;

/// Highest FIRMWARE_VER_CODE this client knows to exist in the field on any
/// population (fork is at 22, moving to 23 on firmware#1448; stock is at 14).
/// A report far above this is treated as malformed rather than capable.
const int maxKnownVerCode = 32;

/// Classifies the connected radio from its device-info reply and the parsed
/// firmware-version string.
///
/// [deviceInfo] is the raw RESP_CODE_DEVICE_INFO frame. [firmwareVersion] is
/// the version string already extracted from it (null when absent/unreadable);
/// it is a SECONDARY signal — absence never blocks, only a positive
/// contradiction does. Task #878 replaces the contains-check below with the
/// full dual-format parser.
///
/// D1 SEAM: when the firmware ships its durable population marker, this
/// function is the single place that learns to read it; callers and the
/// [Classification] contract do not change.
Classification classifyDevicePopulation({
  required Uint8List deviceInfo,
  required String? firmwareVersion,
}) {
  final length = deviceInfo.length;

  // Malformed: too short to even carry a ver code, per the connector's own
  // minimum (frame.length < 4 is discarded there too).
  if (length < 4) {
    return Classification(
      population: DevicePopulation.stockLegacy,
      conflict: false,
      evidence: 'malformed device-info (len=$length)',
    );
  }

  final verCode = deviceInfo[1];
  final forkShape = length > stockDeviceInfoLength;
  final versionLooksStock = _versionLooksStock(firmwareVersion);

  if (verCode > maxKnownVerCode) {
    return Classification(
      population: DevicePopulation.stockLegacy,
      conflict: true,
      evidence: 'ver $verCode above any known population (len=$length)',
    );
  }

  if (forkShape) {
    if (versionLooksStock == false) {
      // Positively Offband: fork-length frame AND the dual version form.
      // Every verified fork build reports the dual form, including release
      // images' X-X shape (firmware#691) and bench builds' git-describe
      // suffixes, so requiring it costs nothing real and stops a corrupted
      // stock frame from unlocking fork frames.
      return Classification(
        population: DevicePopulation.offband,
        conflict: false,
        evidence: 'caps byte present (len=$length, ver=$verCode)',
      );
    }
    // Stock version string, or no readable version at all: the shape says
    // fork but nothing corroborates it, so no fork frames get emitted on
    // this connection (Gemini review, task #875 finding 1A).
    return Classification(
      population: DevicePopulation.stockLegacy,
      conflict: true,
      evidence:
          'fork-shape frame (len=$length) but version string '
          '"$firmwareVersion" does not corroborate',
    );
  }

  if (versionLooksStock == false) {
    // Stock-shape frame carrying the Offband dual version form: the inverse
    // conflict (Gemini review, task #875 finding 2). A fork device that
    // failed to append its caps bytes lands here instead of stockModern,
    // which keeps CLI frame 66 away from a device that may not have it.
    return Classification(
      population: DevicePopulation.stockLegacy,
      conflict: true,
      evidence:
          'stock-shape frame (len=$length) but Offband version string '
          '"$firmwareVersion"',
    );
  }

  if (verCode >= stockCliMinVerCode) {
    return Classification(
      population: DevicePopulation.stockModern,
      conflict: false,
      evidence: 'stock-shape frame, ver=$verCode >= $stockCliMinVerCode',
    );
  }

  return Classification(
    population: DevicePopulation.stockLegacy,
    conflict: false,
    evidence: 'stock-shape frame, ver=$verCode',
  );
}

/// What a firmware-version string positively claims about the population.
enum VersionStringShape {
  /// Single `vX.Y.Z` (or `X.Y.Z`): the stock FIRMWARE_VERSION form.
  stock,

  /// The Offband dual form: a semver, a dash, then more — covering
  /// `<ob>-<mc>` ("1.4.0-1.17.0"), the release-image `X-X` shape
  /// ("1.4.0-1.4.0", firmware#691), and bench builds' git-describe tails
  /// ("1.1.0-4-g9f2e1c3-dirty").
  offbandDual,

  /// Absent, empty, or nothing this parser recognizes. Never corroborates
  /// anything: the classifier treats it as a missing signal, which on a
  /// fork-shape frame means fail closed.
  unknown,
}

// Known limitation (Gemini review, #878): a stock PRE-RELEASE string of the
// form "v1.19.0-rc1" would parse as the dual form. On a stock-shape frame
// that is the inverse conflict and fails closed to stockLegacy — the safe
// direction (the device loses the CLI offer, nothing misfires). Upstream has
// not shipped suffixed FIRMWARE_VERSION strings to date; revisit only if one
// appears in the field rather than inventing its format here.
final RegExp _semver = RegExp(r'^v?\d+\.\d+\.\d+$');
final RegExp _dualPrefix = RegExp(r'^v?\d+\.\d+\.\d+-.+$');

/// Parses the device-info firmware-version field into its population claim
/// (#878). Pure and total: any input maps to exactly one shape.
VersionStringShape classifyVersionString(String? version) {
  if (version == null) return VersionStringShape.unknown;
  final v = version.trim();
  if (v.isEmpty) return VersionStringShape.unknown;
  if (_semver.hasMatch(v)) return VersionStringShape.stock;
  if (_dualPrefix.hasMatch(v)) return VersionStringShape.offbandDual;
  return VersionStringShape.unknown;
}

/// Adapter kept for the classifier's tri-state contract: true = positively
/// stock, false = positively Offband, null = no signal.
bool? _versionLooksStock(String? version) {
  switch (classifyVersionString(version)) {
    case VersionStringShape.stock:
      return true;
    case VersionStringShape.offbandDual:
      return false;
    case VersionStringShape.unknown:
      return null;
  }
}
