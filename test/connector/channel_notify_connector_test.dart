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
import 'package:meshcore_open/connector/offband_capability_advert.dart';
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

    test('NOTHING reads device-info offset 87 (#1096)', () {
      // The permanent rule out of the collision: no Offband field is ever
      // appended to upstream's device-info frame. Three features each computed
      // 87 as the next free byte and each was right in isolation.
      //
      // Behavioural rather than a source grep, so it keeps holding if the read
      // comes back spelled differently. Byte 87 is set to every bit, and every
      // capability answer must be identical to the frame that has no byte 87
      // at all.
      connector.handleFrameForTest(deviceInfo(caps2: 0x80, length: 85));
      final capsWithout = connector.offbandCaps2;
      final withoutByte87 = [
        connector.supportsChannelNotify,
        connector.supportsDisplayRotation,
        connector.supportsButtonMatrix,
        connector.supportsNotifyScope,
        connector.supportsTunes,
        connector.supportsGpsMode,
        connector.supportsScreenSettings,
      ];
      final ackWithout = connector.ackCapacity;

      connector.handleFrameForTest(
        deviceInfo(caps2: 0x80, length: 88, caps3: 0xFF),
      );

      expect(
        [
          connector.supportsChannelNotify,
          connector.supportsDisplayRotation,
          connector.supportsButtonMatrix,
          connector.supportsNotifyScope,
          connector.supportsTunes,
          connector.supportsGpsMode,
          connector.supportsScreenSettings,
        ],
        withoutByte87,
        reason: 'a byte at offset 87 changed a capability',
      );
      expect(connector.ackCapacity, ackWithout);
      // The raw byte too, not only the named getters. Comparing getters alone
      // is a hole: a leak into a caps bit that has no getter yet (0x04
      // INDICATORS, for one) moves nothing this test can see. Caught by
      // deliberately reintroducing such a read and watching this pass.
      expect(
        connector.offbandCaps2,
        capsWithout,
        reason: 'offset 87 contaminated the caps byte read at 84',
      );
    });

    test('a stock-shaped radio exposes nothing, whatever its bytes', () {
      final stock = Uint8List(82);
      stock[0] = 13;
      stock[1] = 14;
      connector.handleFrameForTest(stock);

      expect(connector.supportsChannelNotify, isFalse);
      expect(connector.supportsDisplayRotation, isFalse);
      expect(connector.ackCapacity, isNull);
    });
  });

  // ---- A4: advert precedence over the caps bit (#1097) ----------------------

  group('A4 advert precedence', () {
    /// A `0xC5` `0x1C` reply carrying [tags] as zero-length records.
    Uint8List advertReply(List<int> tags) {
      final f = <int>[cmdOffbandDeviceUi, offbandUiInfoGet];
      for (final t in tags) {
        f.addAll([t, 0x00]);
      }
      return Uint8List.fromList(f);
    }

    /// `[0xC5][0x7F][0x05]`: this radio does not implement the advert.
    Uint8List advertUnsupported() => Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiErr,
      offbandUiErrReasonMalformed,
    ]);

    test('the zero-payload advert request goes out on connect', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x80));
      expect(
        sent.any(
          (f) =>
              f.length == 2 &&
              f[0] == cmdOffbandDeviceUi &&
              f[1] == offbandUiInfoGet,
        ),
        isTrue,
        reason:
            'the request must be exactly two bytes to make err 5 mean '
            '"predates the advert" rather than "malformed payload"',
      );
    });

    test(
      'before any answer the caps bit still decides, so nothing regresses',
      () {
        connector.handleFrameForTest(deviceInfo(caps2: 0x80));
        expect(connector.capabilityAdvertState, CapabilityAdvertState.unknown);
        expect(connector.supportsChannelNotify, isTrue);
      },
    );

    test('an advert WITH the tag grants it even with the caps bit clear', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));
      expect(connector.supportsChannelNotify, isFalse);

      connector.handleFrameForTest(advertReply([offbandInfoTagChanNotify]));

      expect(connector.capabilityAdvertState, CapabilityAdvertState.advertised);
      expect(
        connector.supportsChannelNotify,
        isTrue,
        reason:
            'once the bit is retired under contract section 4, the tag is '
            'the only thing left saying the feature exists',
      );
    });

    test('an advert WITHOUT the tag revokes it even with the caps bit set', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x80));
      expect(connector.supportsChannelNotify, isTrue);

      connector.handleFrameForTest(advertReply([offbandInfoTagAckCapacity]));

      expect(connector.supportsChannelNotify, isFalse);
    });

    test('err 5 falls back to the caps bit, which is the flashed T1000-E', () {
      // firmware 4e5a6c85 answers 0x18/0x19 and carries caps2 0x80, but
      // predates 0x1C. Tag-only gating would take the control away from it.
      connector.handleFrameForTest(deviceInfo(caps2: 0x80));
      connector.handleFrameForTest(advertUnsupported());

      expect(
        connector.capabilityAdvertState,
        CapabilityAdvertState.unsupported,
      );
      expect(connector.supportsChannelNotify, isTrue);
    });

    test('err 5 with the bit clear grants nothing', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));
      connector.handleFrameForTest(advertUnsupported());

      expect(connector.supportsChannelNotify, isFalse);
      expect(connector.supportsDisplayRotation, isFalse);
    });

    test('rotation is tag-gated with NO caps-bit fallback', () {
      // Deliberate: 0x1A/0x1B were claimed in the same merge as the advert, so
      // no firmware can rotate but not advertise. INDICATORS 0x04 must not
      // open it.
      connector.handleFrameForTest(deviceInfo(caps2: 0x04));
      expect(connector.supportsDisplayRotation, isFalse);

      connector.handleFrameForTest(advertUnsupported());
      expect(connector.supportsDisplayRotation, isFalse);

      connector.handleFrameForTest(
        advertReply([offbandInfoTagDisplayRotation]),
      );
      expect(connector.supportsDisplayRotation, isTrue);
    });

    test('ACK capacity comes from the tag value, and absence is not zero', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x80));
      connector.handleFrameForTest(advertReply([offbandInfoTagChanNotify]));
      expect(connector.ackCapacity, isNull);

      connector.handleFrameForTest(
        Uint8List.fromList([
          cmdOffbandDeviceUi,
          offbandUiInfoGet,
          offbandInfoTagAckCapacity,
          0x01,
          0x20,
        ]),
      );
      expect(connector.ackCapacity, 0x20);
    });

    test('an unknown tag does not disturb the known gates', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));
      connector.handleFrameForTest(
        Uint8List.fromList([
          cmdOffbandDeviceUi,
          offbandUiInfoGet,
          0x5A,
          0x02,
          0xDE,
          0xAD,
          offbandInfoTagChanNotify,
          0x00,
        ]),
      );
      expect(connector.supportsChannelNotify, isTrue);
      expect(connector.supportsDisplayRotation, isFalse);
    });

    test('a new device-info drops the previous radio advert', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));
      connector.handleFrameForTest(advertReply([offbandInfoTagChanNotify]));
      expect(connector.supportsChannelNotify, isTrue);

      // A different radio, no advert answer yet.
      connector.handleFrameForTest(deviceInfo(caps2: 0x00));

      expect(connector.capabilityAdvertState, CapabilityAdvertState.unknown);
      expect(
        connector.supportsChannelNotify,
        isFalse,
        reason: "one radio's tags must never answer for another",
      );
    });

    test('a refusal with a write outstanding belongs to the WRITE', () async {
      // The error frame names no sub-code. Claiming it for the advert would
      // hide a genuinely refused write and wrongly mark the radio as predating
      // the advert.
      connector.handleFrameForTest(deviceInfo(caps2: 0x80));
      await connector.setChannelNotify(0, RadioChannelNotify.off);
      connector.handleFrameForTest(advertUnsupported());

      expect(
        connector.capabilityAdvertState,
        CapabilityAdvertState.unknown,
        reason: 'the advert must not claim a write refusal',
      );
      expect(connector.deviceUiError, isNotNull);
    });
  });
}
