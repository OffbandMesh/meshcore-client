import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';

void main() {
  group('capability gating on caps byte 2 (#474/#475)', () {
    test('requires the explicit bit', () {
      expect(firmwareSupportsButtonMatrix(offbandCap2ButtonMatrix), isTrue);
      expect(firmwareSupportsNotifyScope(offbandCap2NotifyScope), isTrue);
    });

    test('false when the other feature bit is set but not this one', () {
      expect(firmwareSupportsButtonMatrix(offbandCap2NotifyScope), isFalse);
      expect(firmwareSupportsNotifyScope(offbandCap2ButtonMatrix), isFalse);
    });

    test('absent byte 2 is unsupported, not an error', () {
      expect(firmwareSupportsButtonMatrix(null), isFalse);
      expect(firmwareSupportsNotifyScope(null), isFalse);
      expect(firmwareSupportsButtonMatrix(0x00), isFalse);
    });

    test('the two bits do not collide', () {
      expect(offbandCap2ButtonMatrix & offbandCap2NotifyScope, equals(0));
    });
  });

  group('request frames', () {
    test('command bytes do not collide with the shipped fork commands', () {
      final used = {
        cmdOffbandGps,
        cmdOffbandBlock,
        cmdOffbandFemLna,
        cmdOffbandCaplog,
      };
      expect(used.contains(cmdOffbandDeviceUi), isFalse);
    });

    test('matrix get and set encode as documented', () {
      expect(buildButtonMatrixGetFrame(), equals([0xC5, 0x03]));
      expect(
        buildButtonMatrixSetFrame(
          ButtonSequence.double,
          ButtonAction.sendAdvert,
        ),
        equals([0xC5, 0x04, 0x01, 0x01]),
      );
    });

    test('scope get and set encode as documented', () {
      expect(buildNotifyScopeGetFrame(), equals([0xC5, 0x01]));
      expect(
        buildNotifyScopeSetFrame(DeviceNotifyScope.self),
        equals([0xC5, 0x02, 0x01]),
      );
    });
  });

  group('button matrix GET parse', () {
    test('reads the supported mask and the assignment rows', () {
      // supported = advert | gps, two rows: single->none, double->advert
      final mask = ButtonAction.sendAdvert.mask | ButtonAction.toggleGps.mask;
      final reply = parseButtonMatrixReply(
        Uint8List.fromList([0xC5, 0x03, mask, 2, 0x00, 0x00, 0x01, 0x01]),
      );
      expect(reply, isNotNull);
      expect(reply!.isError, isFalse);
      final m = reply.matrix!;
      expect(m.assignments[ButtonSequence.single], ButtonAction.none);
      expect(m.assignments[ButtonSequence.double], ButtonAction.sendAdvert);
      expect(m.supports(ButtonAction.sendAdvert), isTrue);
      expect(m.supports(ButtonAction.toggleGps), isTrue);
      expect(m.supports(ButtonAction.batteryBeep), isFalse);
    });

    test('unassigned is always offered so a sequence can be cleared', () {
      final m = ButtonMatrix(assignments: const {}, supportedActions: 0);
      expect(m.supports(ButtonAction.none), isTrue);
      expect(m.availableActions, contains(ButtonAction.none));
    });

    test('a lying count byte cannot read past the frame', () {
      // count says 5 rows, only one is present.
      final reply = parseButtonMatrixReply(
        Uint8List.fromList([0xC5, 0x03, 0xFF, 5, 0x00, 0x01]),
      );
      expect(reply, isNotNull);
      expect(reply!.matrix!.assignments.length, equals(1));
    });

    test('unknown sequence or action codes are skipped, not guessed', () {
      final reply = parseButtonMatrixReply(
        Uint8List.fromList([0xC5, 0x03, 0xFF, 2, 0x7E, 0x01, 0x01, 0x7E]),
      );
      expect(reply!.matrix!.assignments, isEmpty);
    });

    test('truncated GET yields null rather than throwing', () {
      for (final f in [
        <int>[0xC5],
        <int>[0xC5, 0x03],
        <int>[0xC5, 0x03, 0x00],
      ]) {
        expect(parseButtonMatrixReply(Uint8List.fromList(f)), isNull);
      }
    });

    test('a foreign command byte is not claimed', () {
      expect(
        parseButtonMatrixReply(Uint8List.fromList([0xC3, 0x01, 0x00])),
        isNull,
      );
      expect(
        parseNotifyScopeReply(Uint8List.fromList([0xC3, 0x01, 0x00])),
        isNull,
      );
    });
  });

  group('error replies carry the device reason', () {
    test('known reason codes map to their message', () {
      final reply = parseButtonMatrixReply(
        Uint8List.fromList([0xC5, 0x7F, 0x03]),
      );
      expect(reply!.isError, isTrue);
      // Firmware-owned reason codes (FuchsiaCreek, 2026-08-01): 1 unsupported
      // action, 2 unknown sequence, 3 no buzzer, 4 no GPS, 5 malformed.
      expect(reply.errorMessage, ButtonConfigError.noBuzzer.message);
      expect(ButtonConfigError.noBuzzer.code, equals(0x03));
      expect(ButtonConfigError.unknownSequence.code, equals(0x02));
      expect(ButtonConfigError.noGps.code, equals(0x04));
      expect(ButtonConfigError.malformed.code, equals(0x05));
    });

    test(
      'an unknown reason is surfaced with its raw code, never swallowed',
      () {
        final reply = parseButtonMatrixReply(
          Uint8List.fromList([0xC5, 0x7F, 0x5A]),
        );
        expect(reply!.isError, isTrue);
        expect(reply.errorMessage, contains('0x5a'));
      },
    );

    test('the shared error sub-code is owned by one parser, not both', () {
      // Both surfaces ride 0xC5, so 0x7F must be handled exactly once or an
      // error would be processed twice by the dispatcher.
      final frame = Uint8List.fromList([0xC5, 0x7F, 0x04]);
      expect(parseButtonMatrixReply(frame)!.isError, isTrue);
      expect(parseNotifyScopeReply(frame), isNull);
    });
  });

  group('notification scope parse', () {
    test('reads each scope', () {
      for (final s in DeviceNotifyScope.values) {
        final reply = parseNotifyScopeReply(
          Uint8List.fromList([0xC5, 0x01, s.code]),
        );
        expect(reply!.scope, equals(s));
      }
    });

    test('an unknown scope is an error, not a silent default', () {
      final reply = parseNotifyScopeReply(
        Uint8List.fromList([0xC5, 0x01, 0x40]),
      );
      expect(reply!.isError, isTrue);
      expect(reply.scope, isNull);
      expect(reply.errorMessage, contains('0x40'));
    });

    test('truncated scope reply yields null', () {
      expect(parseNotifyScopeReply(Uint8List.fromList([0xC5, 0x01])), isNull);
    });
  });

  group('SET echo', () {
    test('confirmed assignment folds into the held matrix', () {
      final reply = parseButtonMatrixReply(
        Uint8List.fromList([0xC5, 0x04, 0x02, 0x03]),
      );
      expect(reply!.setSequence, ButtonSequence.triple);
      expect(reply.setAction, ButtonAction.cycleNotifyScope);

      final before = ButtonMatrix(
        assignments: const {ButtonSequence.triple: ButtonAction.none},
        supportedActions: 0xFF,
      );
      final after = before.withAssignment(reply.setSequence!, reply.setAction!);
      expect(
        after.assignments[ButtonSequence.triple],
        ButtonAction.cycleNotifyScope,
      );
      expect(after.supportedActions, equals(0xFF));
    });
  });

  // #969: GPS mode and Power save over 0xC5 0x0D / 0x0E, per the contract on
  // meshcore-firmware#1789. Reply is 14 bytes:
  // [0xC5][sub][mode][stored][ps_ok][activity][interval_s:4 LE][wait_s:4 LE]
  group('GPS mode capability (caps byte 2 0x20)', () {
    test('requires the explicit bit', () {
      expect(firmwareSupportsGpsMode(offbandCap2GpsMode), isTrue);
      expect(firmwareSupportsGpsMode(offbandCap2NotifyScope), isFalse);
      expect(firmwareSupportsGpsMode(null), isFalse);
    });

    test('the new bits collide with no allocated caps-byte-2 bit', () {
      // Firmware allocates 0x01 scope, 0x02 matrix, 0x04 indicators, 0x08
      // packet hash (OffbandConfigProtocol.h on firmware-base).
      const allocated = 0x01 | 0x02 | 0x04 | 0x08;
      expect(offbandCap2GpsMode & allocated, equals(0));
      expect(offbandCap2ChannelTune & allocated, equals(0));
      expect(offbandCap2GpsMode & offbandCap2ChannelTune, equals(0));
      expect(offbandCap2GpsMode, equals(0x20));
      expect(offbandCap2ChannelTune, equals(0x10));
    });
  });

  group('GPS mode frames', () {
    test('get encodes as documented', () {
      expect(buildGpsModeGetFrame(), equals([0xC5, 0x0D]));
    });

    test('set carries the mode and a little-endian interval', () {
      expect(
        buildGpsModeSetFrame(GpsMode.powerSave, 3600),
        equals([0xC5, 0x0E, 0x02, 0x10, 0x0E, 0x00, 0x00]),
      );
      expect(
        buildGpsModeSetFrame(GpsMode.off, 0),
        equals([0xC5, 0x0E, 0x00, 0x00, 0x00, 0x00, 0x00]),
      );
    });

    test('mode wire values match the firmware enum', () {
      expect(GpsMode.off.code, equals(0));
      expect(GpsMode.on.code, equals(1));
      expect(GpsMode.powerSave.code, equals(2));
    });
  });

  group('GPS mode reply parse', () {
    Uint8List reply(
      int sub, {
      int mode = 2,
      int stored = 2,
      int psOk = 1,
      int activity = 4,
      int interval = 3600,
      int wait = 2880,
    }) => Uint8List.fromList([
      0xC5,
      sub,
      mode,
      stored,
      psOk,
      activity,
      interval & 0xFF,
      (interval >> 8) & 0xFF,
      (interval >> 16) & 0xFF,
      (interval >> 24) & 0xFF,
      wait & 0xFF,
      (wait >> 8) & 0xFF,
      (wait >> 16) & 0xFF,
      (wait >> 24) & 0xFF,
    ]);

    test('reads every field from a GET reply', () {
      final r = parseGpsModeReply(reply(0x0D));
      expect(r, isNotNull);
      expect(r!.isError, isFalse);
      final g = r.gps!;
      expect(g.mode, GpsMode.powerSave);
      expect(g.storedMode, equals(2));
      expect(g.powerSaveAvailable, isTrue);
      expect(g.activity, GpsActivity.backedOff);
      expect(g.intervalSeconds, equals(3600));
      expect(g.waitSeconds, equals(2880));
    });

    test('a SET reply has the same shape and is the stored state', () {
      final r = parseGpsModeReply(reply(0x0E, interval: 300));
      expect(r!.sub, equals(0x0E));
      expect(r.gps!.intervalSeconds, equals(300));
    });

    test('the raw 0xFF never-set byte is kept beside the resolved mode', () {
      final g = parseGpsModeReply(reply(0x0D, mode: 1, stored: 0xFF))!.gps!;
      expect(g.mode, GpsMode.on);
      expect(g.storedMode, equals(0xFF));
    });

    test('ps_ok 0 means Power save is not offered', () {
      final g = parseGpsModeReply(reply(0x0D, mode: 1, psOk: 0))!.gps!;
      expect(g.powerSaveAvailable, isFalse);
    });

    test('the full 32-bit interval and wait survive', () {
      final g = parseGpsModeReply(
        reply(0x0D, interval: 0xFFFFFFFF, wait: 0x01020304),
      )!.gps!;
      expect(g.intervalSeconds, equals(0xFFFFFFFF));
      expect(g.waitSeconds, equals(0x01020304));
    });

    test('each activity byte maps to its state', () {
      const expected = {
        0: GpsActivity.off,
        1: GpsActivity.on,
        2: GpsActivity.searching,
        3: GpsActivity.sleeping,
        4: GpsActivity.backedOff,
      };
      expected.forEach((code, activity) {
        final g = parseGpsModeReply(reply(0x0D, activity: code))!.gps!;
        expect(g.activity, activity, reason: 'activity byte $code');
      });
    });

    test('an unknown activity from newer firmware is not guessed at', () {
      final g = parseGpsModeReply(reply(0x0D, activity: 0x33))!.gps!;
      expect(g.activity, isNull);
      expect(g.mode, GpsMode.powerSave);
    });

    test('an unknown resolved mode is a visible error, not a default', () {
      final r = parseGpsModeReply(reply(0x0D, mode: 7));
      expect(r!.isError, isTrue);
      expect(r.gps, isNull);
      expect(r.errorMessage, contains('0x07'));
    });

    test('a truncated reply yields null rather than a partial state', () {
      final full = reply(0x0D);
      for (var n = 2; n < 14; n++) {
        expect(
          parseGpsModeReply(Uint8List.sublistView(full, 0, n)),
          isNull,
          reason: 'length $n',
        );
      }
    });

    test('other 0xC5 sub-codes are not claimed', () {
      expect(parseGpsModeReply(Uint8List.fromList([0xC5, 0x01, 0x00])), isNull);
      expect(parseGpsModeReply(Uint8List.fromList([0xC5, 0x7F, 0x04])), isNull);
    });
  });

  group('long press is not assignable', () {
    test('no sequence models a long press', () {
      // Firmware reserves long press for CLI rescue and power off. Exposing it
      // would let a user lock themselves out of a screenless device.
      expect(ButtonSequence.values.length, equals(4));
      expect(
        ButtonSequence.values.map((s) => s.label).join(' ').toLowerCase(),
        isNot(contains('long')),
      );
    });
  });
}
