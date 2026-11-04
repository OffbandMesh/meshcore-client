import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/offband_capability_advert.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';

/// #1095: the `0xC5` `0x1C` capability advert.
///
/// The contract these pin is firmware `docs/offband_info_frame_contract.md`
/// revision 2 plus `OffbandConfigProtocol.h`, both merged on `firmware-base`
/// (PR OffbandMesh/meshcore-firmware#2000, `28785ebf`). The header is the
/// registry; the contract's §5 table is a convenience copy.
///
/// The load-bearing group is `unknown tags`. "A client built today must stay
/// correct against firmware emitting tags it has never heard of. Failing on an
/// unknown tag is non-conforming." Everything else can regress visibly; that
/// one regresses as a client that stops working when firmware grows.
void main() {
  group('request frames', () {
    test('the whole-advert request carries ZERO payload', () {
      // Load-bearing. `[0xC5][0x7F][0x05]` is also what a known sub-code
      // returns for a malformed payload, so only a zero-payload request makes
      // that answer mean "this radio predates the advert". A stray third byte
      // here would make the fallback undetectable.
      expect(buildCapabilityAdvertRequestFrame(), [
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
      ]);
    });

    test('the resume request carries exactly the cursor byte', () {
      expect(buildCapabilityAdvertResumeFrame(0x03), [
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        0x03,
      ]);
    });

    test('a cursor outside one byte is refused rather than truncated', () {
      expect(() => buildCapabilityAdvertResumeFrame(256), throwsArgumentError);
      expect(() => buildCapabilityAdvertResumeFrame(-1), throwsArgumentError);
    });
  });

  group('not an advert', () {
    test('a different command byte is not ours', () {
      expect(parseCapabilityAdvertReply([0xC6, offbandUiInfoGet]), isNull);
    });

    test('a different sub-code is not ours', () {
      expect(parseCapabilityAdvertReply([cmdOffbandDeviceUi, 0x18]), isNull);
    });

    test('a truncated header is not ours', () {
      expect(parseCapabilityAdvertReply([cmdOffbandDeviceUi]), isNull);
      expect(parseCapabilityAdvertReply(const <int>[]), isNull);
    });

    test('the 0x7F error frame is NOT parsed as an advert', () {
      // The fallback path depends on this error reaching the error handler
      // rather than being swallowed here as an empty advert. An empty advert
      // and "predates the advert" gate differently.
      expect(
        parseCapabilityAdvertReply([cmdOffbandDeviceUi, offbandUiErr, 0x05]),
        isNull,
      );
    });
  });

  group('records', () {
    test('a reply with no records is valid and not an error', () {
      // What a cursor above every available tag returns.
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
      ]);
      expect(advert, isNotNull);
      expect(advert!.tags, isEmpty);
      expect(advert.malformed, isFalse);
      expect(advert.continueCursor, isNull);
    });

    test('a len 0 record means SUPPORTED, not empty and not absent', () {
      // The normal case, and the one most likely to be broken by someone
      // treating the value rather than the key as the answer.
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.tags[offbandInfoTagChanNotify], isEmpty);
      expect(advert.malformed, isFalse);
    });

    test('an absent tag is absent, and is not a zero value', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
      ])!;
      expect(advert.has(offbandInfoTagDisplayRotation), isFalse);
      expect(advert.byteValue(offbandInfoTagDisplayRotation), isNull);
    });

    test('several records parse, and a carried value is readable', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
        offbandInfoTagDisplayRotation,
        0x00,
        offbandInfoTagAckCapacity,
        0x01,
        0x10,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.has(offbandInfoTagDisplayRotation), isTrue);
      expect(advert.byteValue(offbandInfoTagAckCapacity), 0x10);
      expect(advert.malformed, isFalse);
    });

    test(
      'byteValue is null for a multi-byte or empty value, never coerced',
      () {
        final advert = parseCapabilityAdvertReply([
          cmdOffbandDeviceUi,
          offbandUiInfoGet,
          offbandInfoTagChanNotify,
          0x00,
          0x40,
          0x02,
          0xAA,
          0xBB,
        ])!;
        expect(advert.byteValue(offbandInfoTagChanNotify), isNull);
        expect(advert.byteValue(0x40), isNull);
      },
    );

    test(
      'position is never relied on, so out-of-order records still parse',
      () {
        // "Clients MUST NOT rely on record position. Ascending order exists for
        // the cursor, not for counting."
        final advert = parseCapabilityAdvertReply([
          cmdOffbandDeviceUi,
          offbandUiInfoGet,
          offbandInfoTagAckCapacity,
          0x01,
          0x08,
          offbandInfoTagChanNotify,
          0x00,
        ])!;
        expect(advert.has(offbandInfoTagChanNotify), isTrue);
        expect(advert.byteValue(offbandInfoTagAckCapacity), 0x08);
      },
    );
  });

  group('unknown tags', () {
    test('an unknown tag is skipped by len and the rest still parses', () {
      // LOAD-BEARING. Firmware will emit tags this build has never heard of.
      // A client that drops the frame, or that loses the records after the
      // unknown one, stops working the day firmware grows a feature.
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        0x55,
        0x03,
        0xDE,
        0xAD,
        0xBE,
        offbandInfoTagChanNotify,
        0x00,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.has(0x55), isTrue);
      expect(advert.malformed, isFalse);
    });

    test('an unknown zero-length tag does not stall the parse', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        0x7E,
        0x00,
        0x7F,
        0x00,
        offbandInfoTagDisplayRotation,
        0x00,
      ])!;
      expect(advert.has(offbandInfoTagDisplayRotation), isTrue);
      expect(advert.malformed, isFalse);
    });

    test('a long run of unknown tags is all kept', () {
      final frame = <int>[cmdOffbandDeviceUi, offbandUiInfoGet];
      for (var tag = 0x20; tag < 0x30; tag++) {
        frame.addAll([tag, 0x01, tag]);
      }
      frame.addAll([offbandInfoTagChanNotify, 0x00]);
      final advert = parseCapabilityAdvertReply(frame)!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.byteValue(0x2F), 0x2F);
      expect(advert.malformed, isFalse);
    });
  });

  group('malformed', () {
    test(
      'a record running past the frame keeps the good records before it',
      () {
        // Firmware must not split a record across frames, so this is a firmware
        // fault. Capability absence is safe (the feature hides); discarding a
        // whole good reply over a bad trailing byte is not.
        final advert = parseCapabilityAdvertReply([
          cmdOffbandDeviceUi,
          offbandUiInfoGet,
          offbandInfoTagChanNotify,
          0x00,
          offbandInfoTagAckCapacity,
          0x04,
          0x01,
        ])!;
        expect(advert.has(offbandInfoTagChanNotify), isTrue);
        expect(advert.has(offbandInfoTagAckCapacity), isFalse);
        expect(advert.malformed, isTrue);
      },
    );

    test('a tag with no length byte is malformed, earlier records survive', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
        offbandInfoTagDisplayRotation,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.has(offbandInfoTagDisplayRotation), isFalse);
      expect(advert.malformed, isTrue);
    });

    test('tag 0x00 is not valid and stops the parse', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
        0x00,
        0x00,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.malformed, isTrue);
    });

    test('a repeated tag keeps the FIRST value and is flagged', () {
      // A later record must not silently redefine a capability.
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagAckCapacity,
        0x01,
        0x08,
        offbandInfoTagAckCapacity,
        0x01,
        0x40,
      ])!;
      expect(advert.byteValue(offbandInfoTagAckCapacity), 0x08);
      expect(advert.malformed, isTrue);
    });
  });

  group('continuation', () {
    test('TAG_CONTINUE yields the cursor and the records before it', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
        offbandInfoTagContinue,
        0x01,
        offbandInfoTagAckCapacity,
      ])!;
      expect(advert.has(offbandInfoTagChanNotify), isTrue);
      expect(advert.continueCursor, offbandInfoTagAckCapacity);
      expect(advert.malformed, isFalse);
    });

    test('a reply without TAG_CONTINUE is complete', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagChanNotify,
        0x00,
      ])!;
      expect(advert.continueCursor, isNull);
    });

    test('TAG_CONTINUE with a length other than 1 is malformed', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagContinue,
        0x02,
        0x01,
        0x02,
      ])!;
      expect(advert.continueCursor, isNull);
      expect(advert.malformed, isTrue);
    });

    test('records after TAG_CONTINUE are flagged, not guessed at', () {
      final advert = parseCapabilityAdvertReply([
        cmdOffbandDeviceUi,
        offbandUiInfoGet,
        offbandInfoTagContinue,
        0x01,
        0x03,
        offbandInfoTagChanNotify,
        0x00,
      ])!;
      expect(advert.continueCursor, 0x03);
      expect(advert.malformed, isTrue);
      expect(advert.has(offbandInfoTagChanNotify), isFalse);
    });

    test('the continuation ceiling is bounded', () {
      // An unbounded request loop driven by device data is a worse failure
      // than a truncated capability list.
      expect(offbandInfoMaxContinuations, greaterThan(0));
      expect(offbandInfoMaxContinuations, lessThanOrEqualTo(16));
    });
  });

  group('the registry numbers', () {
    test('every tag and the sub-code match the merged firmware header', () {
      // Transcribed from `OffbandConfigProtocol.h` on `firmware-base` at
      // `28785ebf`. Do not "fix" a failure here by editing the expectation to
      // match the code: read the header.
      expect(offbandUiInfoGet, 0x1C);
      expect(offbandInfoTagChanNotify, 0x01);
      expect(offbandInfoTagDisplayRotation, 0x02);
      expect(offbandInfoTagAckCapacity, 0x03);
      expect(offbandInfoTagContinue, 0xFF);
    });
  });
}
