// E1.2 (#880): the conformance matrix — every capability gate against every
// population fixture (plan E1.2; INVESTIGATION.md §B3). This is the epic's
// verification: it proves the F1 pieces cohere, it is not a re-run of the
// unit tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/device_population.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/observer_config_client.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List frameOf({
  required int length,
  required int verCode,
  String? version,
  int caps = 0,
  int caps2 = 0,
}) {
  final f = Uint8List(length);
  if (length > 0) f[0] = 13;
  if (length > 1) f[1] = verCode;
  if (version != null && length >= 80) {
    final v = ascii.encode(version);
    f.setRange(60, 60 + v.length, v);
  }
  if (length > 82) f[82] = caps;
  if (length > 84) f[84] = caps2;
  return f;
}

/// One population fixture: the frame a device of that population sends, and
/// the capability doors that must (not) open.
class Fixture {
  const Fixture(
    this.name,
    this.frame, {
    required this.population,
    required this.offbandGps,
    required this.offbandBlock,
    required this.femLna,
    required this.buttonMatrix,
    required this.notifyScope,
    required this.pktHash,
    required this.observerConfig,
    required this.companionStats,
  });

  final String name;
  final Uint8List frame;
  final DevicePopulation population;
  final bool offbandGps;
  final bool offbandBlock;
  final bool femLna;
  final bool buttonMatrix;
  final bool notifyScope;
  final bool pktHash;
  final bool observerConfig;
  final bool companionStats;
}

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (_) {};
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  final fixtures = <Fixture>[
    Fixture(
      'stock 1.17.x (82B, ver 13)',
      frameOf(length: 82, verCode: 13, version: 'v1.17.1'),
      population: DevicePopulation.stockLegacy,
      offbandGps: false,
      offbandBlock: false,
      femLna: false,
      buttonMatrix: false,
      notifyScope: false,
      pktHash: false,
      observerConfig: false,
      companionStats: true,
    ),
    Fixture(
      'stock 1.18.0 (82B, ver 14)',
      frameOf(length: 82, verCode: 14, version: 'v1.18.0'),
      population: DevicePopulation.stockModern,
      offbandGps: false,
      offbandBlock: false,
      femLna: false,
      buttonMatrix: false,
      notifyScope: false,
      pktHash: false,
      observerConfig: false,
      companionStats: true,
    ),
    Fixture(
      'Offband observer, all caps lit (85B, ver 22)',
      frameOf(
        length: 85,
        verCode: 22,
        version: '1.4.0-1.17.0',
        caps: 0x27, // observer 0x01 | block 0x02 | fem 0x04 | caplog 0x20
        caps2: 0x0F,
      ),
      population: DevicePopulation.offband,
      offbandGps: true,
      offbandBlock: true,
      femLna: true,
      buttonMatrix: true,
      notifyScope: true,
      pktHash: true,
      observerConfig: true,
      companionStats: true,
    ),
    Fixture(
      'Offband companion, no cap bits set (83B, ver 22)',
      frameOf(length: 83, verCode: 22, version: '1.4.0-1.17.0'),
      population: DevicePopulation.offband,
      offbandGps: true, // presence-gate: caps byte exists
      offbandBlock: false,
      femLna: false,
      buttonMatrix: false,
      notifyScope: false,
      pktHash: false,
      observerConfig: false,
      companionStats: true,
    ),
    Fixture(
      'conflict: fork shape, stock string (85B, ver 14)',
      frameOf(
        length: 85,
        verCode: 14,
        version: 'v1.18.0',
        caps: 0xFF,
        caps2: 0xFF,
      ),
      population: DevicePopulation.stockLegacy,
      offbandGps: false,
      offbandBlock: false,
      femLna: false,
      buttonMatrix: false,
      notifyScope: false,
      pktHash: false,
      observerConfig: false,
      companionStats: true,
    ),
    Fixture(
      'malformed (3B)',
      frameOf(length: 3, verCode: 0),
      population: DevicePopulation.stockLegacy,
      offbandGps: false,
      offbandBlock: false,
      femLna: false,
      buttonMatrix: false,
      notifyScope: false,
      pktHash: false,
      observerConfig: false,
      companionStats: false, // ver code never parsed from a 3-byte frame
    ),
  ];

  for (final f in fixtures) {
    test('matrix: ${f.name}', () {
      connector.handleFrameForTest(f.frame);
      if (f.frame.length >= 4) {
        expect(connector.classification?.population, f.population,
            reason: 'population');
      }
      expect(connector.supportsOffbandGps, f.offbandGps, reason: 'gps 0xC1');
      expect(connector.supportsOffbandBlock, f.offbandBlock, reason: 'block');
      expect(connector.supportsOffbandFemLna, f.femLna, reason: 'fem 0xC3');
      expect(connector.supportsButtonMatrix, f.buttonMatrix,
          reason: 'button matrix 0xC5');
      expect(connector.supportsNotifyScope, f.notifyScope,
          reason: 'notify scope 0xC5');
      expect(connector.supportsPktHash, f.pktHash, reason: 'pkt hash 0xC6');
      expect(
        ObserverConfigClient.supportsConfig(
          firmwareVerCode: connector.firmwareVerCode ?? 0,
          offbandCaps: connector.offbandCaps ?? 0,
        ),
        f.observerConfig,
        reason: '0xC0 config',
      );
      expect(connector.supportsCompanionRadioStats, f.companionStats,
          reason: 'pre-split stats >=8');
    });
  }
}
