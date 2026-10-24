// #969: the connector side of GPS mode over 0xC5 0x0D / 0x0E. Pins the gate
// (no 0x20, no frame), the bytes a write sends, that a mode change resends the
// radio's own interval rather than inventing one, that a refusal lands on the
// GPS surface, and that the legacy `gps` custom-var mirror follows the device.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RESP_CODE_DEVICE_INFO from an Offband radio, caps byte 2 at offset 84.
///
/// The population classifier honors caps bytes only on a fork-length frame
/// with the dual version form, so a stock-looking frame would (correctly) have
/// its caps ignored. This is the shape a real Offband radio sends.
List<int> deviceInfo({required int caps2}) {
  final v = ascii.encode('1.5.0-1.17.0');
  final f = Uint8List(85);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  f[84] = caps2;
  return f;
}

/// `[0xC5][sub][mode][stored][ps_ok][activity][interval:4 LE][wait:4 LE]`
List<int> gpsReply({
  int sub = 0x0D,
  int mode = 1,
  int stored = 1,
  int psOk = 1,
  int activity = 1,
  int interval = 3600,
  int wait = 0,
}) {
  final f = Uint8List(14);
  f[0] = 0xC5;
  f[1] = sub;
  f[2] = mode;
  f[3] = stored;
  f[4] = psOk;
  f[5] = activity;
  final d = ByteData.sublistView(f);
  d.setUint32(6, interval, Endian.little);
  d.setUint32(10, wait, Endian.little);
  return f;
}

/// RESP_CODE_CUSTOM_VARS, `key:value` pairs comma-separated.
List<int> customVars(String body) => [21, ...ascii.encode(body), 0];

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late List<List<int>> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    sent = [];
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = (data) => sent.add(data.toList());
    connector.setConnectedForTest();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  bool sentGps(int sub) => sent.any(
    (f) => f.length >= 2 && f[0] == cmdOffbandDeviceUi && f[1] == sub,
  );

  test('a radio advertising 0x20 is asked for its GPS state', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    await Future<void>.delayed(Duration.zero);

    expect(connector.supportsGpsMode, isTrue);
    expect(sentGps(offbandUiGpsGet), isTrue);
  });

  test('a radio without 0x20 never sees a GPS frame', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x01));
    await connector.requestGpsMode();
    await connector.setGpsMode(GpsMode.on, intervalSeconds: 0);

    expect(connector.supportsGpsMode, isFalse);
    expect(sentGps(offbandUiGpsGet), isFalse);
    expect(sentGps(offbandUiGpsSet), isFalse);
  });

  test('the reply becomes the state the screen reads', () {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(
      gpsReply(mode: 2, stored: 2, activity: 4, interval: 900, wait: 2880),
    );

    final g = connector.gpsModeState!;
    expect(g.mode, GpsMode.powerSave);
    expect(g.activity, GpsActivity.backedOff);
    expect(g.intervalSeconds, equals(900));
    expect(g.waitSeconds, equals(2880));
  });

  test('a mode change resends the radio\'s current interval', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(gpsReply(mode: 1, interval: 3600));
    sent.clear();

    await connector.setGpsMode(GpsMode.powerSave);

    expect(sent, equals([buildGpsModeSetFrame(GpsMode.powerSave, 3600)]));
  });

  test('an explicit interval is sent as given', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(gpsReply(mode: 2, interval: 3600));
    sent.clear();

    await connector.setGpsMode(GpsMode.powerSave, intervalSeconds: 120);

    expect(sent, equals([buildGpsModeSetFrame(GpsMode.powerSave, 120)]));
  });

  test('a write before any read is refused visibly, nothing sent', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    sent.clear();

    await connector.setGpsMode(GpsMode.on);

    expect(sentGps(offbandUiGpsSet), isFalse);
    expect(connector.deviceUiError, isNotNull);
    expect(connector.deviceUiErrorSurface, DeviceUiSurface.gpsMode);
  });

  test('a refusal after a GPS write is the GPS screen\'s, in its words', () {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(gpsReply(mode: 1, psOk: 0));
    connector.setGpsMode(GpsMode.powerSave);
    connector.handleFrameForTest([0xC5, 0x7F, 0x01]);

    expect(connector.deviceUiErrorSurface, DeviceUiSurface.gpsMode);
    expect(connector.deviceUiError, 'This radio cannot run Power save');
    // The state is not touched by a refusal: the device did not change.
    expect(connector.gpsModeState!.mode, GpsMode.on);
  });

  test('a refusal with no GPS write outstanding is not claimed by GPS', () {
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest([0xC5, 0x7F, 0x04]);

    expect(connector.deviceUiError, isNotNull);
    expect(connector.deviceUiErrorSurface, isNull);
  });

  test('a confirmed Off updates the gps custom-var mirror', () {
    connector.handleFrameForTest(customVars('gps:1,gps_interval:900'));
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(gpsReply(sub: 0x0E, mode: 0, stored: 2));

    expect(connector.currentCustomVars!['gps'], equals('0'));
    // Off kept the remembered Power-save byte.
    expect(connector.gpsModeState!.storedMode, equals(2));
  });

  test('a radio that reported no gps var does not get one invented', () {
    connector.handleFrameForTest(customVars('gps_interval:900'));
    connector.handleFrameForTest(deviceInfo(caps2: 0x20));
    connector.handleFrameForTest(gpsReply(mode: 1));

    expect(connector.currentCustomVars!.containsKey('gps'), isFalse);
  });
}
