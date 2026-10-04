/// Which firmware the fake radio plays. The difference is what DEVICE_INFO
/// reports and whether Offband (0xC0-0xCF) commands are answered.
///
/// A4 (#769) builds these from the firmware's protocol manifests; until then
/// [offband] and [stock] carry the values read from firmware source:
/// - Offband: `examples/companion_radio/MyMesh.h:22` (FIRMWARE_VER_CODE 22) and
///   the DEVICE_INFO tail at MyMesh.cpp:2437-2504.
/// - Stock: upstream meshcore-dev/MeshCore `a366955c` (v1.17.1,
///   FIRMWARE_VER_CODE 13), whose DEVICE_INFO ends after path_hash_mode.
class FakeRadioProfile {
  const FakeRadioProfile({
    required this.name,
    required this.firmwareVerCode,
    required this.versionString,
    required this.offband,
    this.offbandCaps = 0,
    this.femLnaEnabled = false,
    this.offbandCaps2 = 0,
    this.ledEnabled = 0,
    this.displayMode = 0,
  });

  final String name;
  final int firmwareVerCode;

  /// The 20-byte version field of DEVICE_INFO.
  final String versionString;

  /// True for Offband firmware: the extended DEVICE_INFO tail is sent and
  /// Offband commands are answered. Stock rejects them as unknown commands.
  final bool offband;
  final int offbandCaps;
  final bool femLnaEnabled;
  final int offbandCaps2;
  final int ledEnabled;
  final int displayMode;

  static const FakeRadioProfile offbandDefault = FakeRadioProfile(
    name: 'offband',
    firmwareVerCode: 22,
    versionString: '1.5.0-1.17.1',
    offband: true,
    // OFFBAND_CAP_BLOCK (0x02) | OFFBAND_CAP_CAPLOG (0x20), always set on the
    // companion (MyMesh.cpp:2448,2453; OffbandConfigProtocol.h:301,305); no
    // observer, no FEM LNA.
    offbandCaps: 0x02 | 0x20,
    // OFFBAND_CAP2_PKT_HASH, advertised unconditionally (MyMesh.cpp:2499).
    offbandCaps2: 0x08,
  );

  static const FakeRadioProfile stockDefault = FakeRadioProfile(
    name: 'stock',
    firmwareVerCode: 13,
    versionString: 'v1.17.1',
    offband: false,
  );
}
