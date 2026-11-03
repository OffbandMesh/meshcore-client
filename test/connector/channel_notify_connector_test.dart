// #544 Epic A (#1068): the red baseline for the RADIO's per-channel notify
// mode over 0xC5 0x18 / 0x19.
//
// The feature this pins is that there are TWO independent settings: the app's
// per-channel mode drives the PHONE, the radio's drives the BUZZER, and
// neither moves the other (owner, 2026-11-03). The independence group below is
// the load-bearing part -- it is what stops the two being quietly re-merged by
// a later change.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/offband_channel_notify.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RESP_CODE_DEVICE_INFO from an Offband radio (fork length, dual version so
/// the population classifier corroborates it). Caps byte 2 at offset 84;
/// pass [length] 88 with [caps3] to carry a third caps byte at offset 87.
Uint8List deviceInfo({
  required int caps2,
  int length = 85,
  int caps3 = 0,
  int ledByte = 0,
  int displayByte = 0,
}) {
  final v = ascii.encode('1.5.0-1.17.0');
  final f = Uint8List(length);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  if (length >= 85) f[84] = caps2;
  if (length >= 86) f[85] = ledByte;
  if (length >= 87) f[86] = displayByte;
  if (length >= 88) f[87] = caps3;
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

  bool sentChannelNotify() => sent.any(
    (f) =>
        f.length >= 2 &&
        f[0] == cmdOffbandDeviceUi &&
        (f[1] == offbandUiChannelNotifyGet ||
            f[1] == offbandUiChannelNotifySet),
  );

  // ---- A1: the radio's modes ------------------------------------------------

  group('A1 radio channel notify', () {
    test('the wire bytes are the documented ones', () async {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      sent.clear();

      await connector.requestChannelNotify(2);
      await connector.setChannelNotify(2, RadioChannelNotify.mentions);

      expect(
        sent,
        equals([
          [0xC5, 0x18, 0x02],
          [0xC5, 0x19, 0x02, 0x02],
        ]),
      );
    });

    test('a reply sets that slot, and only that slot', () {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      connector.handleFrameForTest([0xC5, 0x18, 0x01, 0x02]);

      expect(connector.channelNotifyFor(1), RadioChannelNotify.mentions);
      expect(connector.channelNotifyFor(0), isNull);
      expect(connector.channelNotifyFor(2), isNull);
    });

    test('mode 0 is unset, and is distinct from Off', () {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      connector.handleFrameForTest([0xC5, 0x18, 0x00, 0x00]);
      connector.handleFrameForTest([0xC5, 0x18, 0x01, 0x03]);

      expect(connector.channelNotifyFor(0), RadioChannelNotify.unset);
      expect(connector.channelNotifyFor(1), RadioChannelNotify.off);
    });

    test('a write is not shown until the radio confirms it', () async {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      await connector.setChannelNotify(3, RadioChannelNotify.off);

      expect(connector.channelNotifyFor(3), isNull);

      connector.handleFrameForTest([0xC5, 0x19, 0x03, 0x03]);
      expect(connector.channelNotifyFor(3), RadioChannelNotify.off);
    });

    test('an unknown mode byte is dropped, never guessed at', () {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      connector.handleFrameForTest([0xC5, 0x18, 0x04, 0x09]);

      expect(connector.channelNotifyFor(4), isNull);
      expect(parseChannelNotifyReply([0xC5, 0x18, 0x04, 0x09]), isNull);
    });

    test('state does not survive a change of radio', () {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      connector.handleFrameForTest([0xC5, 0x18, 0x01, 0x01]);
      expect(connector.channelNotifyFor(1), RadioChannelNotify.all);

      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      expect(connector.channelNotifyFor(1), isNull);
    });
  });

  // ---- A2: the two settings are independent ---------------------------------

  group('A2 independence of app and radio settings', () {
    test('changing the app mode emits no radio frame', () async {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      sent.clear();

      final settings = AppSettingsService();
      await settings.loadSettings();
      await settings.setChannelNotifyMode(
        devicePrefix: 'aabbccddee',
        pskHex: '00112233445566778899aabbccddeeff',
        channelName: 'skywarn',
        mode: ChannelNotifyMode.off,
      );

      expect(sentChannelNotify(), isFalse);
      expect(sent, isEmpty);
    });

    test('a radio reply does not touch the app store', () async {
      final settings = AppSettingsService();
      await settings.loadSettings();
      const prefix = 'aabbccddee';
      const psk = '00112233445566778899aabbccddeeff';
      await settings.setChannelNotifyMode(
        devicePrefix: prefix,
        pskHex: psk,
        channelName: 'skywarn',
        mode: ChannelNotifyMode.all,
      );

      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      connector.handleFrameForTest([0xC5, 0x18, 0x00, 0x03]);

      expect(
        settings.channelNotifyMode(devicePrefix: prefix, pskHex: psk),
        ChannelNotifyMode.all,
        reason: 'the radio saying Off must not mute the phone',
      );
    });

    test('the app setting works with no radio capability at all', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));
      final settings = AppSettingsService();
      await settings.loadSettings();
      const prefix = 'aabbccddee';
      const psk = '00112233445566778899aabbccddeeff';

      await settings.setChannelNotifyMode(
        devicePrefix: prefix,
        pskHex: psk,
        channelName: 'skywarn',
        mode: ChannelNotifyMode.mentionsOnly,
      );

      expect(connector.supportsChannelNotify, isFalse);
      expect(
        settings.channelNotifyMode(devicePrefix: prefix, pskHex: psk),
        ChannelNotifyMode.mentionsOnly,
      );
    });
  });

  // ---- A3: capability and caps byte 3 ---------------------------------------

  group('A3 capability gating and caps byte 3', () {
    test('without 0x80 no channel-notify frame is ever emitted', () async {
      connector.handleFrameForTest(deviceInfo(caps2: 0x40));
      await connector.requestChannelNotify(0);
      await connector.setChannelNotify(0, RadioChannelNotify.off);

      expect(connector.supportsChannelNotify, isFalse);
      expect(sentChannelNotify(), isFalse);
    });

    test('0x80 is the bit, and other bits do not open it', () {
      connector.handleFrameForTest(deviceInfo(caps2: offbandCap2ChannelNotify));
      expect(connector.supportsChannelNotify, isTrue);

      connector.handleFrameForTest(deviceInfo(caps2: 0x7F));
      expect(connector.supportsChannelNotify, isFalse);
    });

    test('caps byte 3 reads offset 87', () {
      connector.handleFrameForTest(
        deviceInfo(caps2: 0x80, length: 88, caps3: 0x05),
      );
      expect(connector.offbandCaps3, 0x05);
    });

    test('caps byte 3 is null on any shorter frame', () {
      for (final n in [85, 86, 87]) {
        connector.handleFrameForTest(deviceInfo(caps2: 0x80, length: n));
        expect(
          connector.offbandCaps3,
          isNull,
          reason: 'a $n-byte frame carries no byte 3',
        );
      }
    });

    test('85 and 86 are not mistaken for byte 3', () {
      // Those offsets are ui_led_enabled and ui_display_mode. Reading either
      // as a capability mask is the failure this pins.
      connector.handleFrameForTest(
        deviceInfo(
          caps2: 0x80,
          length: 88,
          ledByte: 0xAA,
          displayByte: 0xBB,
          caps3: 0x01,
        ),
      );
      expect(connector.offbandCaps3, 0x01);
      expect(connector.offbandCaps3, isNot(0xAA));
      expect(connector.offbandCaps3, isNot(0xBB));
    });

    test('a stock-shaped radio exposes nothing, whatever its bytes', () {
      final stock = Uint8List(82);
      stock[0] = 13;
      stock[1] = 14;
      connector.handleFrameForTest(stock);

      expect(connector.supportsChannelNotify, isFalse);
      expect(connector.offbandCaps3, isNull);
    });
  });
}
