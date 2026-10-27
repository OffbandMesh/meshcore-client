// #971: the connector side of per-channel tune over 0xC5 0x0B / 0x0C. Pins
// the gate (no 0x10, no frame), the bytes sent, that local state follows only
// the device's re-read reply, that inherit and Silent stay distinct end to
// end, and that a refusal lands on the channel-tune surface.

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

/// RESP_CODE_DEVICE_INFO from an Offband radio (fork length, dual version),
/// caps byte 2 at offset 84. A stock-shaped frame would have its caps ignored.
List<int> deviceInfo({required int caps2}) {
  final v = ascii.encode('1.5.0-1.17.0');
  final f = Uint8List(85);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  f[84] = caps2;
  return f;
}

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

  bool sentTune() => sent.any(
    (f) =>
        f.length >= 2 &&
        f[0] == cmdOffbandDeviceUi &&
        (f[1] == offbandUiChannelTuneGet || f[1] == offbandUiChannelTuneSet),
  );

  test('a radio without 0x10 never sees a channel-tune frame', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x01));
    await connector.requestChannelTune(0);
    await connector.setChannelTune(0, ChannelTune.tune(0));

    expect(connector.supportsTunes, isFalse);
    expect(sentTune(), isFalse);
  });

  test('get and set send the documented bytes', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    sent.clear();

    await connector.requestChannelTune(2);
    await connector.setChannelTune(2, const ChannelTune.inherit());

    expect(
      sent,
      equals([
        [0xC5, 0x0B, 0x02],
        [0xC5, 0x0C, 0x02, 0x00],
      ]),
    );
  });

  test('a write is not shown until the radio confirms it', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    await connector.setChannelTune(2, ChannelTune.tune(5));

    expect(connector.channelTuneFor(2), isNull);

    connector.handleFrameForTest([0xC5, 0x0C, 0x02, 0x06]);
    expect(connector.channelTuneFor(2)!.tuneId, equals(5));
  });

  test('inherit and Silent stay distinct through a round trip', () {
    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    connector.handleFrameForTest([0xC5, 0x0B, 0x00, 0x00]);
    connector.handleFrameForTest([0xC5, 0x0B, 0x01, 0x01]);

    expect(connector.channelTuneFor(0)!.inherits, isTrue);
    expect(connector.channelTuneFor(0)!.isSilent, isFalse);
    expect(connector.channelTuneFor(1)!.isSilent, isTrue);
    expect(connector.channelTuneFor(1)!.inherits, isFalse);
  });

  test('a refusal after a tune write is the tune surface\'s', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    await connector.setChannelTune(2, ChannelTune.tune(99));
    connector.handleFrameForTest([0xC5, 0x7F, 0x05]);

    expect(connector.deviceUiErrorSurface, DeviceUiSurface.channelTune);
    expect(connector.deviceUiError, ButtonConfigError.malformed.message);
    // Refused, so nothing changed on the radio and nothing is shown as set.
    expect(connector.channelTuneFor(2), isNull);
  });

  test('a new radio does not inherit the previous radio\'s tunes', () {
    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    connector.handleFrameForTest([0xC5, 0x0B, 0x00, 0x03]);
    expect(connector.channelTuneFor(0), isNotNull);

    connector.handleFrameForTest(deviceInfo(caps2: 0x10));
    expect(connector.channelTuneFor(0), isNull);
  });
}
