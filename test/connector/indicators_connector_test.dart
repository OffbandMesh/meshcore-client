// #523 / #944: display mode, rotation and the status LED over 0xC5. Display and
// LED are 0x05 to 0x08 (#542) under the INDICATORS caps bit.
//
// ROTATION IS 0x1A / 0x1B, advertised by TAG_DISPLAY_ROTATION in the 0xC5 0x1C
// capability advert (#1098, firmware #1990). It was 0x18 / 0x19 under the
// INDICATORS bit until 2026-11-04, and both of those were wrong:
//
//   0x18 / 0x19 are CHNOTIFY. Firmware 4e5a6c85, already flashed on the
//   owner's T1000-E, answers them as per-channel notify and its SET validates
//   only `mode < 4`, so a rotation SET of 0 landed as a valid notify-mode
//   write on channel slot 0, which is Public, with success reported on BOTH
//   sides. Silent corruption, no error anywhere.
//
//   Discovering rotation by sending the GET and watching for a refusal is
//   forbidden by contract section 3: "what is forbidden is discovering support
//   by trying each feature's sub-code and watching for errors." The tag
//   replaces the probe, so capability and value are no longer conflated.
//
// Pins the gate (the tag, not 0x04 and not a probe), the device-info bytes 85
// and 86, that offset 87 is read by nothing, and that every value follows the
// radio's reply rather than the tap.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/offband_capability_advert.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/connector/offband_indicators.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An Offband device-info reply: caps byte 2 at 84, then LED and display mode.
/// [extra] appends bytes past 86, to prove nothing there is read as rotation.
List<int> deviceInfo({
  int caps2 = offbandCap2Indicators,
  int led = 1,
  int mode = 0,
  List<int> extra = const [],
}) {
  final v = ascii.encode('1.5.0-1.17.0');
  final f = Uint8List(87 + extra.length);
  f[0] = 13;
  f[1] = 22;
  f.setRange(60, 60 + v.length, v);
  f[84] = caps2;
  f[85] = led;
  f[86] = mode;
  f.setRange(87, 87 + extra.length, extra);
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

  bool sentSub(int sub) => sent.any(
    (f) => f.length >= 2 && f[0] == cmdOffbandDeviceUi && f[1] == sub,
  );

  /// A `0xC5` `0x1C` advert reply carrying [tags] as zero-length records.
  List<int> advert(List<int> tags) => [
    cmdOffbandDeviceUi,
    offbandUiInfoGet,
    for (final t in tags) ...[t, 0x00],
  ];

  /// `[0xC5][0x7F][0x05]`: this radio predates the advert.
  List<int> advertUnsupported() => [
    cmdOffbandDeviceUi,
    offbandUiErr,
    offbandUiErrReasonMalformed,
  ];

  /// Connect a radio that ADVERTISES rotation, then answer the GET with
  /// [rotation] degrees. Capability now comes from the tag, and the GET
  /// reports the current value; the two are separate steps on purpose.
  void connectWithRotation(int rotation, {int mode = 0}) {
    connector.handleFrameForTest(deviceInfo(mode: mode));
    connector.handleFrameForTest(
      Uint8List.fromList(advert([offbandInfoTagDisplayRotation])),
    );
    connector.handleFrameForTest([
      cmdOffbandDeviceUi,
      offbandUiRotationGet,
      rotation,
    ]);
    sent.clear();
  }

  group('frames', () {
    test('a mode SET is three bytes, with no rotation in it', () {
      expect(buildDisplaySetFrame(DisplayMode.alwaysOff), [0xC5, 0x06, 2]);
    });

    test('rotation is 0x1A / 0x1B, and NEVER the CHNOTIFY pair', () {
      // The collision, pinned at the wire. 0x18/0x19 against firmware
      // 4e5a6c85 writes a channel-notify mode onto Public with a success
      // reply on both sides.
      expect(buildRotationGetFrame(), [0xC5, 0x1A]);
      expect(buildRotationSetFrame(180), [0xC5, 0x1B, 180]);
      expect(offbandUiRotationGet, isNot(0x18));
      expect(offbandUiRotationSet, isNot(0x19));
    });

    test('a rotation other than 0 or 180 is refused before sending', () {
      expect(() => buildRotationSetFrame(90), throwsArgumentError);
    });

    test('the LED SET is one byte', () {
      expect(buildLedSetFrame(on: false), [0xC5, 0x08, 0]);
    });

    test('a rotation reply carries degrees', () {
      final r = parseIndicatorReply(Uint8List.fromList([0xC5, 0x1B, 180]));
      expect(r!.rotation, 180);
      expect(r.surface, DeviceUiSurface.rotation);
      expect(r.isWrite, isTrue);
    });

    test('an unknown mode or rotation is an error, not a guess', () {
      final mode = parseIndicatorReply(Uint8List.fromList([0xC5, 0x05, 9]));
      expect(mode!.errorMessage, contains('unknown display mode'));
      final rot = parseIndicatorReply(Uint8List.fromList([0xC5, 0x1A, 90]));
      expect(rot!.errorMessage, contains('unknown rotation'));
    });

    test('the indicator parser does not claim the CHNOTIFY pair', () {
      // Belt and braces on the collision: even if a 0x18/0x19 frame reaches
      // this parser, it must not be read as a rotation reply.
      expect(parseIndicatorReply(Uint8List.fromList([0xC5, 0x18, 0])), isNull);
      expect(parseIndicatorReply(Uint8List.fromList([0xC5, 0x19, 0])), isNull);
    });
  });

  test('device-info bytes 85 and 86 render on connect', () {
    connector.handleFrameForTest(deviceInfo(led: 0, mode: 2));

    expect(connector.supportsIndicators, isTrue);
    expect(connector.ledEnabled, isFalse);
    expect(connector.displayMode, DisplayMode.alwaysOff);
  });

  test('a radio without 0x04 never sees an indicator frame', () async {
    connector.handleFrameForTest(deviceInfo(caps2: 0x01));
    await connector.setDisplayMode(DisplayMode.alwaysOn);
    await connector.setLedEnabled(false);

    expect(connector.supportsIndicators, isFalse);
    expect(sentSub(offbandUiDisplaySet), isFalse);
    expect(sentSub(offbandUiLedSet), isFalse);
    expect(sentSub(offbandUiRotationGet), isFalse);
  });

  // #1132 (firmware #2069): display control and LED control are separate tags
  // in the advert. Precedence from the firmware header: the tags decide when
  // the advert carries either; otherwise caps2 0x04 answers both.
  group('display and LED gate on their own tags', () {
    void connectWith({required int caps2, List<int>? tags}) {
      connector.handleFrameForTest(deviceInfo(caps2: caps2));
      if (tags != null) {
        connector.handleFrameForTest(Uint8List.fromList(advert(tags)));
      }
    }

    test(
      'display tag only: display shown, LED hidden and never sent',
      () async {
        connectWith(
          caps2: offbandCap2Indicators,
          tags: [offbandInfoTagDisplayControl],
        );
        sent.clear();

        expect(connector.supportsDisplayControl, isTrue);
        expect(connector.supportsLedControl, isFalse);
        expect(connector.supportsIndicators, isTrue);

        await connector.setLedEnabled(false);
        await connector.setDisplayMode(DisplayMode.alwaysOn);
        expect(sentSub(offbandUiLedSet), isFalse);
        expect(sentSub(offbandUiDisplaySet), isTrue);
      },
    );

    test('LED tag only: LED shown, display hidden and never sent', () async {
      connectWith(
        caps2: offbandCap2Indicators,
        tags: [offbandInfoTagLedControl],
      );
      sent.clear();

      expect(connector.supportsDisplayControl, isFalse);
      expect(connector.supportsLedControl, isTrue);

      await connector.setDisplayMode(DisplayMode.alwaysOn);
      await connector.setLedEnabled(false);
      expect(sentSub(offbandUiDisplaySet), isFalse);
      expect(sentSub(offbandUiLedSet), isTrue);
    });

    test('both tags: both shown', () {
      connectWith(
        caps2: offbandCap2Indicators,
        tags: [offbandInfoTagDisplayControl, offbandInfoTagLedControl],
      );

      expect(connector.supportsDisplayControl, isTrue);
      expect(connector.supportsLedControl, isTrue);
    });

    test('a tag decides even with caps2 0x04 clear', () {
      connectWith(caps2: 0x01, tags: [offbandInfoTagLedControl]);

      expect(connector.supportsDisplayControl, isFalse);
      expect(connector.supportsLedControl, isTrue);
      expect(connector.supportsIndicators, isTrue);
    });

    test('advert without either tag: caps2 0x04 answers both, as today', () {
      connectWith(
        caps2: offbandCap2Indicators,
        tags: [offbandInfoTagDisplayRotation],
      );

      expect(connector.supportsDisplayControl, isTrue);
      expect(connector.supportsLedControl, isTrue);
    });

    test('advert without either tag and caps2 0x04 clear: no Indicators', () {
      connectWith(caps2: 0x01, tags: [offbandInfoTagChanNotify]);

      expect(connector.supportsDisplayControl, isFalse);
      expect(connector.supportsLedControl, isFalse);
      expect(connector.supportsIndicators, isFalse);
    });

    test('a radio that predates the advert: caps2 0x04 answers both', () {
      connector.handleFrameForTest(deviceInfo());
      connector.handleFrameForTest(Uint8List.fromList(advertUnsupported()));

      expect(
        connector.capabilityAdvertState,
        CapabilityAdvertState.unsupported,
      );
      expect(connector.supportsDisplayControl, isTrue);
      expect(connector.supportsLedControl, isTrue);
    });

    test('a radio that predates the advert, caps2 0x04 clear: nothing', () {
      connector.handleFrameForTest(deviceInfo(caps2: 0x01));
      connector.handleFrameForTest(Uint8List.fromList(advertUnsupported()));

      expect(connector.supportsIndicators, isFalse);
    });

    test('before the advert answers, caps2 0x04 answers both', () {
      connectWith(caps2: offbandCap2Indicators);

      expect(connector.capabilityAdvertState, CapabilityAdvertState.unknown);
      expect(connector.supportsDisplayControl, isTrue);
      expect(connector.supportsLedControl, isTrue);
    });

    test('support is never probed: no display or LED GET is sent', () {
      connectWith(
        caps2: offbandCap2Indicators,
        tags: [offbandInfoTagDisplayControl],
      );

      expect(sentSub(offbandUiDisplayGet), isFalse);
      expect(sentSub(offbandUiLedGet), isFalse);
    });

    test('an unknown tag is skipped by its length and kept', () {
      final reply = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagLedControl,
        0x00,
        0x06,
        0x02,
        0xAA,
        0xBB,
        0x07,
        0x00,
      ])!;

      expect(reply.malformed, isFalse);
      expect(reply.has(offbandInfoTagLedControl), isTrue);
      expect(reply.tags[0x06], [0xAA, 0xBB]);
      expect(reply.has(0x07), isTrue);
      expect(resolveIndicatorSupport(offbandCaps2: 0, advert: reply), (
        display: false,
        led: true,
      ));
    });
  });

  group('rotation', () {
    test('the INDICATORS bit alone does NOT open rotation', () {
      // The gate moved to the advert tag. 0x04 means indicators, which is a
      // different capability; gating rotation on it was the old contract.
      connector.handleFrameForTest(deviceInfo());

      expect(connector.supportsIndicators, isTrue);
      expect(connector.supportsDisplayRotation, isFalse);
      expect(sentSub(offbandUiRotationGet), isFalse);
    });

    test('rotation is NOT probed, ever', () {
      // Contract section 3: "what is forbidden is discovering support by
      // trying each feature's sub-code and watching for errors." An advert
      // without the tag must produce no 0x1A on the wire at all.
      connector.handleFrameForTest(deviceInfo());
      connector.handleFrameForTest(
        Uint8List.fromList(advert([offbandInfoTagChanNotify])),
      );

      expect(connector.supportsDisplayRotation, isFalse);
      expect(sentSub(offbandUiRotationGet), isFalse);
    });

    test('a radio that predates the advert gets no rotation and no frame', () {
      connector.handleFrameForTest(deviceInfo());
      connector.handleFrameForTest(Uint8List.fromList(advertUnsupported()));

      expect(connector.supportsDisplayRotation, isFalse);
      expect(sentSub(offbandUiRotationGet), isFalse);
      expect(connector.deviceUiError, isNull, reason: 'not a failure to show');
    });

    test('the tag opens it, and the GET follows', () {
      connector.handleFrameForTest(deviceInfo());
      connector.handleFrameForTest(
        Uint8List.fromList(advert([offbandInfoTagDisplayRotation])),
      );

      expect(connector.supportsDisplayRotation, isTrue);
      expect(sentSub(offbandUiRotationGet), isTrue);
    });

    test(
      'capability and value are separate: the tag does not imply a value',
      () {
        // The old gate was `supportsIndicators && _displayRotation != null`,
        // which made "not answered yet" indistinguishable from "cannot rotate".
        connector.handleFrameForTest(deviceInfo());
        connector.handleFrameForTest(
          Uint8List.fromList(advert([offbandInfoTagDisplayRotation])),
        );

        expect(connector.supportsDisplayRotation, isTrue);
        expect(connector.displayRotation, isNull);
      },
    );

    test('a byte past 86 in device-info is never read as rotation', () {
      connector.handleFrameForTest(deviceInfo(extra: [180]));

      expect(connector.supportsDisplayRotation, isFalse);
      expect(connector.displayRotation, isNull);
    });

    test('the value arrives from the GET reply', () {
      connectWithRotation(180);

      expect(connector.supportsDisplayRotation, isTrue);
      expect(connector.displayRotation, 180);
    });

    test('an advert refusal does not swallow the next write refusal', () {
      connector.handleFrameForTest(deviceInfo());
      connector.handleFrameForTest(Uint8List.fromList(advertUnsupported()));
      connector.handleFrameForTest(
        Uint8List.fromList(advert([offbandInfoTagDisplayRotation])),
      );
      sent.clear();

      expect(connector.deviceUiError, isNull);
    });

    test('a rotation write before the tag sends nothing and says so', () async {
      connector.handleFrameForTest(deviceInfo());
      sent.clear();

      await connector.setDisplayRotation(180);

      expect(sent, isEmpty);
      expect(connector.deviceUiErrorSurface, DeviceUiSurface.rotation);
      expect(connector.deviceUiError, isNotNull);
    });

    test('a rotation write sends 0x1B and follows the echo', () async {
      connectWithRotation(0);

      await connector.setDisplayRotation(180);
      expect(sent, [buildRotationSetFrame(180)]);
      expect(connector.displayRotation, 0);

      connector.handleFrameForTest([0xC5, 0x1B, 180]);
      expect(connector.displayRotation, 180);
    });

    test(
      'a rotation SET refused with reason 10 says so on its surface',
      () async {
        connectWithRotation(0);

        await connector.setDisplayRotation(180);
        connector.handleFrameForTest([0xC5, 0x7F, 0x0A]);

        expect(connector.deviceUiErrorSurface, DeviceUiSurface.rotation);
        expect(
          connector.deviceUiError,
          "This radio's display cannot be rotated",
        );
        expect(connector.displayRotation, 0);
      },
    );
  });

  test('a mode write never touches rotation', () async {
    connectWithRotation(180);

    await connector.setDisplayMode(DisplayMode.alwaysOff);
    expect(sent, [buildDisplaySetFrame(DisplayMode.alwaysOff)]);

    connector.handleFrameForTest([0xC5, 0x06, 2]);
    expect(connector.displayMode, DisplayMode.alwaysOff);
    expect(connector.displayRotation, 180);
  });

  test('state follows the echo, not the request', () async {
    connectWithRotation(0);
    await connector.setDisplayMode(DisplayMode.alwaysOn);

    expect(connector.displayMode, DisplayMode.auto);

    connector.handleFrameForTest([0xC5, 0x06, 1]);
    expect(connector.displayMode, DisplayMode.alwaysOn);

    connector.handleFrameForTest([0xC5, 0x08, 0]);
    expect(connector.ledEnabled, isFalse);
  });

  test('a board without a display refuses on the display surface', () async {
    connectWithRotation(0);
    await connector.setDisplayMode(DisplayMode.alwaysOff);
    connector.handleFrameForTest([0xC5, 0x7F, 0x06]);

    expect(connector.deviceUiErrorSurface, DeviceUiSurface.display);
    expect(connector.deviceUiError, 'This radio has no display or LED to set');
    expect(connector.displayMode, DisplayMode.auto);
  });

  test('an LED refusal lands on the LED surface', () async {
    connectWithRotation(0);
    await connector.setLedEnabled(false);
    connector.handleFrameForTest([0xC5, 0x7F, 0x06]);

    expect(connector.deviceUiErrorSurface, DeviceUiSurface.led);
    expect(connector.ledEnabled, isTrue);
  });

  test('a stock-shape frame reads no indicator bytes', () {
    final stock = Uint8List(82);
    stock[0] = 13;
    stock[1] = 22;
    connector.handleFrameForTest(stock);

    expect(connector.supportsIndicators, isFalse);
    expect(connector.displayMode, isNull);
    expect(connector.ledEnabled, isNull);
  });
}
