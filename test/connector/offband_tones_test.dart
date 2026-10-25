// #970, #986: the tune codec over 0xC5, against the contract in
// meshcore-firmware 3e788e2a OffbandConfigProtocol.h, and the ports of its
// RTTTL validator and slot-name rule.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/offband_tones.dart';

void main() {
  group('frames', () {
    test('event tone get and set', () {
      expect(buildEventToneGetFrame(ToneEvent.dm), equals([0xC5, 0x0F, 0]));
      expect(
        buildEventToneSetFrame(ToneEvent.sent, 9),
        equals([0xC5, 0x10, 5, 9]),
      );
    });

    test('play, slot get and slot read', () {
      expect(buildTunePlayFrame(8), equals([0xC5, 0x11, 8]));
      expect(buildSlotGetFrame(7), equals([0xC5, 0x09, 7]));
      expect(buildSlotReadFrame(2, 15), equals([0xC5, 0x12, 2, 15]));
    });

    test('slot set carries offset, more and the bytes', () {
      expect(
        buildSlotSetFrame(1, 15, true, [0x61, 0x62]),
        equals([0xC5, 0x0A, 1, 15, 1, 0x61, 0x62]),
      );
      // The empty final chunk at offset 0 is how a slot is cleared.
      expect(buildSlotSetFrame(1, 0, false, []), equals([0xC5, 0x0A, 1, 0, 0]));
    });

    test('a slot past the eight is refused before it is sent', () {
      expect(() => buildSlotGetFrame(8), throwsArgumentError);
      expect(() => buildSlotReadFrame(-1, 0), throwsArgumentError);
    });
  });

  group('replies', () {
    Uint8List f(List<int> b) => Uint8List.fromList(b);

    test('event tone keeps stored and effective apart', () {
      final r = parseTuneReply(f([0xC5, 0x0F, 0, 0xFF, 1]))!;
      expect(r.eventTone!.event, ToneEvent.dm);
      expect(r.eventTone!.state.isRadioDefault, isTrue);
      expect(r.eventTone!.state.effective, 1);
    });

    test('an unknown event is an error, not a guess', () {
      expect(parseTuneReply(f([0xC5, 0x10, 9, 1, 1]))!.isError, isTrue);
    });

    test('slot get: length and name, and an empty slot', () {
      final full = parseTuneReply(
        f([0xC5, 0x09, 0, 142, ...'Mario'.codeUnits]),
      );
      expect(full!.tuneSlot!.info.length, 142);
      expect(full.tuneSlot!.info.name, 'Mario');
      final empty = parseTuneReply(f([0xC5, 0x09, 3, 0]));
      expect(empty!.tuneSlot!.info.isEmpty, isTrue);
    });

    test('slot read chunk and play result', () {
      final c = parseTuneReply(f([0xC5, 0x12, 1, 15, 1, 0x61, 0x62]))!;
      expect(c.slotChunk!.offset, 15);
      expect(c.slotChunk!.more, isTrue);
      expect(c.slotChunk!.bytes, equals([0x61, 0x62]));
      final p = parseTuneReply(f([0xC5, 0x11, 8, 2]))!;
      expect(p.tunePlay!.result, TunePlayResult.soundOff);
    });

    test('truncated replies are dropped', () {
      expect(parseTuneReply(f([0xC5, 0x0F, 0, 1])), isNull);
      expect(parseTuneReply(f([0xC5, 0x12, 1, 0])), isNull);
      expect(parseTuneReply(f([0xC5, 0x11, 8])), isNull);
    });
  });

  group('the picker rule', () {
    test('named built-ins plus filled slots, never id 7 or empty slots', () {
      final slots = {
        0: const TuneSlotInfo(length: 142, name: 'Mario'),
        1: const TuneSlotInfo(length: 0, name: ''),
      };
      expect(offeredTuneIds(slots), equals([0, 1, 2, 3, 4, 5, 6, 8]));
    });

    test('labels', () {
      final slots = {
        0: const TuneSlotInfo(length: 142, name: 'Mario'),
        4: const TuneSlotInfo(length: 20, name: ''),
      };
      expect(tuneLabel(2, slots), 'Kerplop');
      expect(tuneLabel(7, slots), isNull);
      expect(tuneLabel(8, slots), 'Mario');
      expect(tuneLabel(12, slots), 'Slot 5');
      expect(tuneLabel(9, slots), isNull);
    });
  });

  group('rtttlProblem, ported from firmware', () {
    final cases = <String, RtttlProblem>{
      'Mario:d=4,o=5,b=100:16e6,16e6': RtttlProblem.ok,
      'MsgRcv3:d=4,o=6,b=200:32e,32g,32b,16c7': RtttlProblem.ok,
      'ack:d=32,o=8,b=120:c': RtttlProblem.ok,
      '': RtttlProblem.empty,
      'no colon here': RtttlProblem.missingColon,
      ':d=4:c': RtttlProblem.noName,
      'x:d=:c': RtttlProblem.badDefault,
      'x:o=55:c': RtttlProblem.badDefault,
      'Doorbell:d=4,o=5,b=0:8e6': RtttlProblem.zeroTempo,
      'x:b=:c': RtttlProblem.zeroTempo,
      'x:d=4:': RtttlProblem.noNotes,
      'x:b8,c': RtttlProblem.ambiguousNote,
      'x:c:d': RtttlProblem.strayColon,
      'x: d=4,o=5,b=100:c': RtttlProblem.strayColon,
    };
    cases.forEach((tune, want) {
      test('"$tune" is ${want.name}', () {
        expect(rtttlProblem(tune), want);
      });
    });

    test('every problem has firmware\'s words', () {
      expect(RtttlProblem.zeroTempo.text, 'b= must be 1 or more');
      expect(RtttlProblem.missingColon.text, 'Needs name:notes');
    });
  });

  group('fixRtttlDefaultsOrder', () {
    // The owner's tune, 2026-10-25: o= before d=, and b= twice.
    const takeOnMe = 'Take On Me:o=5,d=8,b=160,b=160:f#,f#,f#,d,p,b4,p,e,p,e5';

    test('the owner\'s tune is refused, and the fix plays', () {
      expect(rtttlProblem(takeOnMe), RtttlProblem.strayColon);
      final fixed = fixRtttlDefaultsOrder(takeOnMe);
      expect(fixed, 'Take On Me:d=8,o=5,b=160:f#,f#,f#,d,p,b4,p,e,p,e5');
      expect(rtttlProblem(fixed!), RtttlProblem.ok);
    });

    test('a valid tune needs no fix', () {
      expect(fixRtttlDefaultsOrder('x:d=4,o=5,b=100:c'), isNull);
    });

    test('two different tempos are not the app\'s to choose', () {
      expect(fixRtttlDefaultsOrder('x:o=5,b=160,b=200:c'), isNull);
    });

    test('a header fix never hides a second problem', () {
      // Reordered, b=0 still divides by zero in the player.
      expect(fixRtttlDefaultsOrder('x:o=5,d=8,b=0:c'), isNull);
      // A key the player does not know is not a reorder.
      expect(fixRtttlDefaultsOrder('x:o=5,l=8:c'), isNull);
    });

    test('spaces around the defaults are dropped', () {
      expect(fixRtttlDefaultsOrder('x: o=5 , d=8 :c'), 'x:d=8,o=5:c');
    });
  });

  group('deriveSlotName', () {
    test('the text before the first colon, trimmed and capped at 12', () {
      expect(deriveSlotName('  Mario :d=4:c'), 'Mario');
      expect(deriveSlotName('ABCDEFGHIJKLMNOP:c'), 'ABCDEFGHIJKL');
      expect(deriveSlotName('no colon'), '');
    });
  });
}
