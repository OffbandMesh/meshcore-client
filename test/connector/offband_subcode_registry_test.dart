import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/connector/offband_capability_advert.dart';
import 'package:meshcore_open/connector/offband_channel_notify.dart';
import 'package:meshcore_open/connector/offband_device_ui.dart';
import 'package:meshcore_open/connector/offband_screen_settings.dart';
import 'package:meshcore_open/connector/offband_tones.dart';

/// #1093: the mechanical check that was missing when two sessions both built
/// on `0xC5` sub-codes 0x18/0x19.
///
/// Nothing failed when that happened. Both features compiled, both passed
/// their own tests, both reviewed clean, and the collision would only have
/// appeared on the owner's hardware as one feature mis-dispatching in a way
/// that looked like either one being broken. The root cause was that
/// `firmware-base` stopped at 0x0A, so every allocation from 0x0B to 0x19 lived
/// only on unmerged branches and "take the next free pair" was unanswerable
/// from the merged tree.
///
/// That is now fixed at the source: firmware
/// `docs/offband_info_frame_contract.md` §2 requires a number to be merged to
/// `firmware-base` BEFORE a plan using it is approved and before any work
/// begins, and the claims live in a merged header the compiler reads.
///
/// This file is the client half: it fails if the client ever double-books a
/// sub-code, and it fails if the client drifts from the firmware registry.
///
/// THE AUTHORITY for this table is firmware
/// `examples/companion_radio/OffbandConfigProtocol.h`. Transcribed from
/// `28785ebf` on `firmware-base`, the merge of PR
/// OffbandMesh/meshcore-firmware#2000 ("claim the wire numbers for the three
/// offset-87 features"), 2026-11-04.
/// `[verified: 2026-11-04, git show origin/firmware-base:...]`
///
/// When firmware allocates a new code, update this table in the same change
/// that consumes it, and say in the PR which firmware commit you transcribed.
/// Do not "fix" a failure here by editing the expectation to match the code.
void main() {
  /// Every `0xC5` sub-code the firmware registry allocates, with the name the
  /// registry gives it. Codes firmware owns but the client does not implement
  /// are listed too, so a future session cannot take one believing it free.
  const registry = <int, String>{
    0x01: 'SCOPE_GET',
    0x02: 'SCOPE_SET',
    0x03: 'MATRIX_GET',
    0x04: 'MATRIX_SET',
    0x05: 'DISPLAY_GET', // #542, firmware-side only so far
    0x06: 'DISPLAY_SET', // #542, firmware-side only so far
    0x07: 'LED_GET', // #542, firmware-side only so far
    0x08: 'LED_SET', // #542, firmware-side only so far
    0x09: 'SLOT_GET',
    0x0A: 'SLOT_SET',
    0x0B: 'CHTUNE_GET',
    0x0C: 'CHTUNE_SET',
    0x0D: 'GPS_GET',
    0x0E: 'GPS_SET',
    0x0F: 'EVTONE_GET',
    0x10: 'EVTONE_SET',
    0x11: 'TUNE_PLAY',
    0x12: 'SLOT_READ',
    0x13: 'SCREEN_GET',
    0x14: 'TEXT_SET',
    0x15: 'SCROFF_SET',
    0x16: 'TZ_SET',
    0x17: 'BATT_SET',
    0x18: 'CHNOTIFY_GET',
    0x19: 'CHNOTIFY_SET',
    0x1A: 'ROTATION_GET',
    0x1B: 'ROTATION_SET',
    0x1C: 'INFO_GET',
    0x7F: 'ERR',
  };

  /// What the client actually emits, by constant. Add a row here whenever a
  /// new sub-code constant is introduced anywhere in `lib/connector/`.
  const clientUses = <String, int>{
    'offbandUiScopeGet': offbandUiScopeGet,
    'offbandUiScopeSet': offbandUiScopeSet,
    'offbandUiMatrixGet': offbandUiMatrixGet,
    'offbandUiMatrixSet': offbandUiMatrixSet,
    'offbandUiSlotGet': offbandUiSlotGet,
    'offbandUiSlotSet': offbandUiSlotSet,
    'offbandUiChannelTuneGet': offbandUiChannelTuneGet,
    'offbandUiChannelTuneSet': offbandUiChannelTuneSet,
    'offbandUiGpsGet': offbandUiGpsGet,
    'offbandUiGpsSet': offbandUiGpsSet,
    'offbandUiEventToneGet': offbandUiEventToneGet,
    'offbandUiEventToneSet': offbandUiEventToneSet,
    'offbandUiTunePlay': offbandUiTunePlay,
    'offbandUiSlotRead': offbandUiSlotRead,
    'offbandUiScreenGet': offbandUiScreenGet,
    'offbandUiTextSet': offbandUiTextSet,
    'offbandUiScreenOffSet': offbandUiScreenOffSet,
    'offbandUiTimeZoneSet': offbandUiTimeZoneSet,
    'offbandUiBatterySet': offbandUiBatterySet,
    'offbandUiChannelNotifyGet': offbandUiChannelNotifyGet,
    'offbandUiChannelNotifySet': offbandUiChannelNotifySet,
    'offbandUiInfoGet': offbandUiInfoGet,
    'offbandUiErr': offbandUiErr,
  };

  test('no two client sub-codes share a value', () {
    // THE CHECK THAT WAS MISSING. #523 rotation and #544 channel notify both
    // took 0x18/0x19; had both landed in the client, this would have caught it
    // before any hardware saw it.
    final byValue = <int, List<String>>{};
    clientUses.forEach((name, code) {
      byValue.putIfAbsent(code, () => []).add(name);
    });
    final doubled = byValue.entries.where((e) => e.value.length > 1).toList();

    expect(
      doubled,
      isEmpty,
      reason: doubled
          .map(
            (e) =>
                '0x${e.key.toRadixString(16).padLeft(2, '0')} is claimed by '
                '${e.value.join(" and ")}',
          )
          .join('; '),
    );
  });

  test('every client sub-code is one firmware actually allocates', () {
    // Catches a code invented client-side, which is how a session takes a
    // number firmware has already spent on an unmerged branch.
    clientUses.forEach((name, code) {
      expect(
        registry.containsKey(code),
        isTrue,
        reason:
            '$name uses 0x${code.toRadixString(16).padLeft(2, '0')}, which is '
            'not in the firmware registry. Get it allocated in '
            'OffbandConfigProtocol.h and MERGED before shipping it.',
      );
    });
  });

  test('the client has not drifted from the registry on a shared code', () {
    // Pins the specific pairs most likely to be re-allocated under pressure.
    expect(registry[offbandUiChannelNotifyGet], 'CHNOTIFY_GET');
    expect(registry[offbandUiChannelNotifySet], 'CHNOTIFY_SET');
    expect(registry[offbandUiChannelTuneGet], 'CHTUNE_GET');
    expect(registry[offbandUiChannelTuneSet], 'CHTUNE_SET');
    expect(registry[offbandUiInfoGet], 'INFO_GET');
    expect(registry[offbandUiErr], 'ERR');
  });

  test(
    'rotation owns 0x1A/0x1B and the client never sends it on 0x18/0x19',
    () {
      // The collision, pinned. A rotation SET on 0x18/0x19 against firmware
      // 4e5a6c85 writes a valid channel-notify mode onto channel slot 0, which
      // is Public and undeletable, and both sides report success.
      expect(registry[0x1A], 'ROTATION_GET');
      expect(registry[0x1B], 'ROTATION_SET');
      expect(offbandUiChannelNotifyGet, 0x18);
      expect(offbandUiChannelNotifySet, 0x19);
    },
  );

  test('0x1D is the next free sub-code', () {
    // Recorded so the next feature does not repeat the guess. The header says
    // it in terms: "Next free sub-code: 0x1D. 0x7F is OFFBAND_UI_ERR and is
    // not available."
    expect(registry.containsKey(0x1D), isFalse);
    expect(clientUses.values.contains(0x1D), isFalse);
  });

  test('the advert tags match the merged registry', () {
    expect(offbandInfoTagChanNotify, 0x01);
    expect(offbandInfoTagDisplayRotation, 0x02);
    expect(offbandInfoTagAckCapacity, 0x03);
    expect(offbandInfoTagContinue, 0xFF);
  });

  test('caps2 0x80 is the last capability bit, and no byte 3 follows it', () {
    // Contract §2, permanent: no Offband field is appended to upstream's
    // device-info frame, ever. Capabilities past this bit are advert TAGS.
    //
    // This asserts the bit value only. The real guard that offset 87 is no
    // longer read is behavioural and lives in
    // channel_notify_connector_test.dart group A3, because a constant test
    // cannot prove the absence of a read.
    expect(offbandCap2ChannelNotify, 0x80);
  });
}
