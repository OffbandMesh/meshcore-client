// #1156 (Epic #1155, firmware #2186 / #2213): an Offband radio offers the CLI
// only when its 0xC5 0x1C advert carries the tag. 0x06 CLI_LOCAL opens the
// Device CLI console (frames 66/29); 0x07 CLI_REMOTE opens remote CLI (TXT type
// 3) and the per-contact permission switch. A present tag is authoritative; an
// advert without it, a radio that predates the advert, and an advert still in
// flight all leave the CLI hidden, which is what every Offband radio had before.
// Stock 1.18 is unchanged: the classifier alone opens it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/device_population.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_capability_advert.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An Offband device-info reply: fork length, dual version string.
Uint8List offbandDeviceInfo() {
  final v = ascii.encode('1.8.0-1.18.0');
  final f = Uint8List(87);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  return f;
}

/// A stock 1.18 device-info reply: exactly 82 bytes, ver 14.
Uint8List stockDeviceInfo({int verCode = 14}) {
  final v = ascii.encode('v1.18.0');
  final f = Uint8List(stockDeviceInfoLength);
  f[0] = 13;
  f[1] = verCode;
  f.setRange(60, 60 + v.length, v);
  return f;
}

/// A `0xC5` `0x1C` advert reply carrying [tags] as zero-length records.
Uint8List advert(List<int> tags) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiInfoGet,
  for (final t in tags) ...[t, 0x00],
]);

/// `[0xC5][0x7F][0x05]`: this radio predates the advert.
Uint8List advertUnsupported() => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiErr,
  offbandUiErrReasonMalformed,
]);

const offband = Classification(
  population: DevicePopulation.offband,
  conflict: false,
  evidence: 'test',
);
const stockModern = Classification(
  population: DevicePopulation.stockModern,
  conflict: false,
  evidence: 'test',
);
const stockLegacy = Classification(
  population: DevicePopulation.stockLegacy,
  conflict: false,
  evidence: 'test',
);

OffbandCapabilityAdvert parsed(List<int> tags) =>
    parseCapabilityAdvertReply(advert(tags))!;

void main() {
  test('the tag numbers are the ones claimed on firmware-base (8d94ef78)', () {
    expect(offbandInfoTagCliLocal, 0x06);
    expect(offbandInfoTagCliRemote, 0x07);
  });

  group('resolveCliSupport', () {
    test('stock 1.18: both, with no advert at all', () {
      expect(resolveCliSupport(classification: stockModern, advert: null), (
        local: true,
        remote: true,
      ));
    });

    test('Offband with both tags: both', () {
      expect(
        resolveCliSupport(
          classification: offband,
          advert: parsed([offbandInfoTagCliLocal, offbandInfoTagCliRemote]),
        ),
        (local: true, remote: true),
      );
    });

    test('Offband with 0x06 only: local, not remote', () {
      expect(
        resolveCliSupport(
          classification: offband,
          advert: parsed([offbandInfoTagCliLocal]),
        ),
        (local: true, remote: false),
      );
    });

    test('Offband with 0x07 only: remote, not local', () {
      expect(
        resolveCliSupport(
          classification: offband,
          advert: parsed([offbandInfoTagCliRemote]),
        ),
        (local: false, remote: true),
      );
    });

    test('Offband advert without either tag: neither (today\'s behavior)', () {
      expect(
        resolveCliSupport(
          classification: offband,
          advert: parsed([offbandInfoTagChanNotify, offbandInfoTagLedControl]),
        ),
        (local: false, remote: false),
      );
    });

    test('Offband with no advert (in flight, or predates it): neither', () {
      expect(resolveCliSupport(classification: offband, advert: null), (
        local: false,
        remote: false,
      ));
    });

    test('stock legacy: neither, even if an advert carried the tags', () {
      // Tags are read only for an Offband radio. Fail closed everywhere else.
      expect(
        resolveCliSupport(
          classification: stockLegacy,
          advert: parsed([offbandInfoTagCliLocal, offbandInfoTagCliRemote]),
        ),
        (local: false, remote: false),
      );
    });

    test('not classified yet: neither', () {
      expect(resolveCliSupport(classification: null, advert: null), (
        local: false,
        remote: false,
      ));
    });
  });

  group('connector', () {
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

    test('Offband radio advertising both tags: both consoles', () {
      connector.handleFrameForTest(offbandDeviceInfo());
      connector.handleFrameForTest(
        advert([offbandInfoTagCliLocal, offbandInfoTagCliRemote]),
      );

      expect(connector.supportsLocalCli, isTrue);
      expect(connector.supportsRemoteCli, isTrue);
    });

    test('Offband radio, advert without the tags: neither', () {
      connector.handleFrameForTest(offbandDeviceInfo());
      connector.handleFrameForTest(advert([offbandInfoTagDisplayRotation]));

      expect(connector.supportsLocalCli, isFalse);
      expect(connector.supportsRemoteCli, isFalse);
    });

    test('Offband radio, advert not answered yet: neither', () {
      connector.handleFrameForTest(offbandDeviceInfo());

      expect(connector.capabilityAdvertState, CapabilityAdvertState.unknown);
      expect(connector.supportsLocalCli, isFalse);
      expect(connector.supportsRemoteCli, isFalse);
    });

    test('Offband radio that predates the advert: neither', () {
      connector.handleFrameForTest(offbandDeviceInfo());
      connector.handleFrameForTest(advertUnsupported());

      expect(
        connector.capabilityAdvertState,
        CapabilityAdvertState.unsupported,
      );
      expect(connector.supportsLocalCli, isFalse);
      expect(connector.supportsRemoteCli, isFalse);
    });

    test('stock 1.18 radio: both, unchanged', () {
      connector.handleFrameForTest(stockDeviceInfo());

      expect(connector.supportsLocalCli, isTrue);
      expect(connector.supportsRemoteCli, isTrue);
    });

    test('stock radio below 1.18: neither, unchanged', () {
      connector.handleFrameForTest(stockDeviceInfo(verCode: 13));

      expect(connector.supportsLocalCli, isFalse);
      expect(connector.supportsRemoteCli, isFalse);
    });

    test('the next radio does not inherit the previous radio\'s tags', () {
      connector.handleFrameForTest(offbandDeviceInfo());
      connector.handleFrameForTest(
        advert([offbandInfoTagCliLocal, offbandInfoTagCliRemote]),
      );
      expect(connector.supportsLocalCli, isTrue);

      // A new device-info drops the old advert, so this radio is gated on its
      // own answer, and it predates the advert.
      connector.handleFrameForTest(offbandDeviceInfo());
      connector.handleFrameForTest(advertUnsupported());

      expect(connector.supportsLocalCli, isFalse);
      expect(connector.supportsRemoteCli, isFalse);
    });
  });
}
