import 'dart:typed_data';

import 'offband_device_ui.dart';

/// The `0xC5` `0x1C` capability advert (#1095, firmware #1994).
///
/// Replaces the practice of appending Offband capability bytes to upstream's
/// `RESP_CODE_DEVICE_INFO` frame. Three features each computed "the next free
/// byte" as **87** and each was right in isolation, and a collision at a frame
/// offset is silent misparsing rather than a refused command. Two permanent
/// rules came out of that (firmware `docs/offband_info_frame_contract.md` §2):
/// no Offband field is ever added to upstream's frame again, and a number is
/// claimed by merge before any work begins.
///
/// THE AUTHORITY for every number here is firmware
/// `examples/companion_radio/OffbandConfigProtocol.h`, merged to
/// `firmware-base` in PR OffbandMesh/meshcore-firmware#2000 (`28785ebf`,
/// 2026-11-04). The contract's §5 table is a convenience copy and the header
/// wins on any disagreement. Do not take a number from an Agent Mail message:
/// that habit is what caused the collision.
const int offbandUiInfoGet = 0x1C;

/// A tag's PRESENCE is the capability. There is no capability bitmap in this
/// frame: tags already answer "is this supported", so a bitmap beside them
/// would be a second source of truth for one question (the defect removed from
/// contract revision 1).
///
/// - `len = 0` means "I have this feature, nothing to report". The normal case.
/// - `len > 0` only where the value is one or two bytes, fixed for the build,
///   and has no sub-code of its own. Everything else is read with its own GET.
/// - **Absent** means the board does not have the feature. Not an error, and
///   not a zero value.
const int offbandInfoTagChanNotify = 0x01;
const int offbandInfoTagDisplayRotation = 0x02;
const int offbandInfoTagAckCapacity = 0x03;
const int offbandInfoTagContinue = 0xFF;

/// `0x00` is not a valid tag.
const int _invalidTag = 0x00;

/// Firmware `OFFBAND_UI_ERR_MALFORMED = 5`.
///
/// The `0xC5` handler returns this reason for BOTH a malformed payload on a
/// known sub-code and a sub-code it does not implement at all. That overload is
/// the entire reason the advert request must carry zero payload: with no
/// payload there is nothing to be malformed, so the answer can only mean the
/// radio does not implement `0x1C`.
const int offbandUiErrReasonMalformed = 0x05;

/// Ceiling on continuation rounds. The advert is a handful of bytes today and
/// no shipping firmware can overflow it, so any long chain is a firmware fault
/// rather than a large reply. Bounded because an unbounded request loop driven
/// by device data is a worse failure than a truncated capability list.
const int offbandInfoMaxContinuations = 8;

/// Request the whole advert. **Zero payload, deliberately.**
///
/// A `[0xC5][0x7F][0x05]` answer to a zero-payload request is unambiguous:
/// reason 5 is also what a KNOWN sub-code returns for a malformed payload, so
/// a request carrying bytes could not be told apart from a device that simply
/// predates the advert.
Uint8List buildCapabilityAdvertRequestFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiInfoGet]);

/// Resume from [cursor], which is the value `TAG_CONTINUE` carried.
Uint8List buildCapabilityAdvertResumeFrame(int cursor) {
  if (cursor < 0 || cursor > 0xFF) {
    throw ArgumentError.value(cursor, 'cursor', 'must be 0 to 255');
  }
  return Uint8List.fromList([cmdOffbandDeviceUi, offbandUiInfoGet, cursor]);
}

/// One `0xC5` `0x1C` reply, parsed.
class OffbandCapabilityAdvert {
  const OffbandCapabilityAdvert({
    required this.tags,
    this.continueCursor,
    this.malformed = false,
  });

  /// Tag to value. An empty value is the `len = 0` case and still means
  /// supported, so membership is the question to ask, never emptiness.
  final Map<int, Uint8List> tags;

  /// Non-null when the reply ended in `TAG_CONTINUE`: re-request with this as
  /// the cursor. A reply without it is complete.
  final int? continueCursor;

  /// A record was unparseable and parsing stopped there. The tags BEFORE it are
  /// still returned, because capability absence is safe (the feature hides)
  /// while discarding a whole good reply over a bad trailing byte is not.
  ///
  /// Firmware must not split a record across frames, so this is a firmware
  /// fault and worth logging rather than swallowing.
  final bool malformed;

  bool has(int tag) => tags.containsKey(tag);

  /// The single-byte value of [tag], or null when the tag is absent or does not
  /// carry exactly one byte. Null is never coerced to 0: "the device did not
  /// say" and "the device said zero" are different answers.
  int? byteValue(int tag) {
    final value = tags[tag];
    if (value == null || value.length != 1) return null;
    return value[0];
  }

  @override
  String toString() {
    final names = tags.keys.toList()..sort();
    return 'advert(tags=[${names.map((t) => '0x${t.toRadixString(16).padLeft(2, '0')}').join(',')}]'
        '${continueCursor == null ? '' : ', continue=0x${continueCursor!.toRadixString(16).padLeft(2, '0')}'}'
        '${malformed ? ', MALFORMED' : ''})';
  }
}

/// Parse a `0xC5` `0x1C` reply. Null when the frame is not one of those at all.
///
/// A reply with no records is valid and means "nothing further", which is what
/// a cursor above every available tag returns. It is not an error.
///
/// Unknown tags are KEPT and skipped by `len`, never rejected: a client built
/// today has to stay correct against firmware emitting tags it has never heard
/// of, and failing on one is non-conforming.
OffbandCapabilityAdvert? parseCapabilityAdvertReply(List<int> frame) {
  if (frame.length < 2) return null;
  if (frame[0] != respCodeOffbandDeviceUi) return null;
  if (frame[1] != offbandUiInfoGet) return null;

  final tags = <int, Uint8List>{};
  int? continueCursor;
  var malformed = false;
  var i = 2;

  while (i < frame.length) {
    final tag = frame[i];
    if (tag == _invalidTag) {
      malformed = true;
      break;
    }
    if (i + 1 >= frame.length) {
      // A tag with no length byte.
      malformed = true;
      break;
    }
    final len = frame[i + 1];
    final valueStart = i + 2;
    final valueEnd = valueStart + len;
    if (valueEnd > frame.length) {
      // A record running past the frame. Firmware must not split one.
      malformed = true;
      break;
    }
    final value = Uint8List.fromList(frame.sublist(valueStart, valueEnd));

    if (tag == offbandInfoTagContinue) {
      if (len != 1) {
        malformed = true;
        break;
      }
      continueCursor = value[0];
      // TAG_CONTINUE is the last record by construction. Anything after it is
      // not something to guess at.
      malformed = valueEnd != frame.length;
      break;
    }

    // Records arrive in ascending tag order, but position is never relied on,
    // so an out-of-order frame still parses. A repeated tag is a firmware
    // fault: keep the FIRST value and say so, rather than letting a later
    // record silently redefine a capability.
    if (tags.containsKey(tag)) {
      malformed = true;
    } else {
      tags[tag] = value;
    }
    i = valueEnd;
  }

  return OffbandCapabilityAdvert(
    tags: tags,
    continueCursor: continueCursor,
    malformed: malformed,
  );
}

/// How far the client has got with asking this radio for its advert.
///
/// Distinguishes "has not answered yet" from "answered, and says it does not
/// have this mechanism". Those lead to different gating, and a single nullable
/// field would conflate them exactly where the collision taught us not to.
enum CapabilityAdvertState {
  /// No request sent, or sent and still outstanding.
  unknown,

  /// A `0x1C` reply arrived and was parsed.
  advertised,

  /// `[0xC5][0x7F][0x05]` to our zero-payload request: this radio predates the
  /// advert, so capability reading falls back to the absolute device-info
  /// offsets that shipped before it.
  unsupported,
}
