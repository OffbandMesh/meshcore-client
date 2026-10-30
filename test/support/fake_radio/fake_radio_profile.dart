import 'fake_radio_manifest.dart';

/// Which firmware the fake radio plays (#769). The difference is what
/// DEVICE_INFO reports and whether Offband commands are answered. Built from a
/// firmware protocol manifest, so codes, bits and versions follow the firmware.
class FakeRadioProfile {
  const FakeRadioProfile({
    required this.name,
    required this.firmwareVerCode,
    required this.versionString,
    required this.offband,
    this.manifest,
    this.offbandCaps = 0,
    this.femLnaEnabled = false,
    this.offbandCaps2 = 0,
    this.ledEnabled = 0,
    this.displayMode = 0,
    this.gpsStatusText = 'detected=0',
  });

  /// A companion build of [manifest]'s firmware.
  ///
  /// Offband capability bits default to the ones every companion sets
  /// unconditionally: OFFBAND_CAP_BLOCK and OFFBAND_CAP_CAPLOG
  /// (MyMesh.cpp:2448,2453) and OFFBAND_CAP2_PKT_HASH (MyMesh.cpp:2499).
  /// Board-dependent bits (observer, FEM LNA, buzzer, button, indicators) are
  /// off unless named.
  factory FakeRadioProfile.fromManifest(
    FakeRadioManifest manifest, {
    Iterable<String> caps = const ['OFFBAND_CAP_BLOCK', 'OFFBAND_CAP_CAPLOG'],
    Iterable<String> caps2 = const ['OFFBAND_CAP2_PKT_HASH'],
  }) {
    final offband = manifest.isOffband;
    return FakeRadioProfile(
      name: manifest.flavor,
      firmwareVerCode: manifest.firmwareVerCode,
      versionString: manifest.deviceInfoVersion,
      offband: offband,
      manifest: manifest,
      offbandCaps: offband ? manifest.capsOf(caps) : 0,
      offbandCaps2: offband ? manifest.capsOf(caps2, second: true) : 0,
    );
  }

  /// The pinned Offband release (`offband-v1.5.0-beta7`).
  factory FakeRadioProfile.offband() =>
      FakeRadioProfile.fromManifest(FakeRadioManifest.pinnedOffband());

  /// The pinned upstream MeshCore release (`companion-v1.17.1`).
  factory FakeRadioProfile.stock() =>
      FakeRadioProfile.fromManifest(FakeRadioManifest.pinnedStock());

  final String name;
  final int firmwareVerCode;

  /// The 20-byte version field of DEVICE_INFO.
  final String versionString;

  /// True for Offband firmware: the extended DEVICE_INFO tail is sent and
  /// Offband commands are answered. Stock rejects them as unknown commands.
  final bool offband;
  final FakeRadioManifest? manifest;
  final int offbandCaps;
  final bool femLnaEnabled;
  final int offbandCaps2;
  final int ledEnabled;
  final int displayMode;

  /// What `sensors.getGpsStatusText` adds after `enabled=N ` in the 0xC1
  /// reply. Board-specific in firmware; a seed value here.
  final String gpsStatusText;
}
