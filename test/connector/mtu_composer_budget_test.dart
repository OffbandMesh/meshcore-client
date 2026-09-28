import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// Characterizes the #592 root cause: on a BLE link whose MTU was never
/// reported, `effectiveMaxFrameSize` falls to the 20-byte floor and the
/// composer byte budget collapses to the values below. These are the numbers
/// both field reports reduced to: "4 characters in a DM", "keyboard dead in
/// every channel".
///
/// The fix is not to change this arithmetic. The frame budget is a write-safety
/// cap and stays honest (#395); the fix is the vendored Windows plugin
/// reporting the real MTU (#686) so a 20-byte frame budget stops occurring on
/// healthy links. The user-facing guard for a collapsed budget is #684.
void main() {
  /// What `effectiveMaxFrameSize` yields for a BLE link with no reported MTU:
  /// flutter_blue_plus defaults `mtuNow` to the 23-byte ATT minimum, minus the
  /// 3-byte ATT header.
  const unknownMtuFrameBudget = 20;

  group('composer budget at the unknown-MTU BLE floor (#592)', () {
    test('a DM composer is left with exactly 4 bytes', () {
      expect(
        maxContactMessageBytes(maxFrameBytes: unknownMtuFrameBudget),
        4,
        reason:
            'the owner typed four characters into a DM and then input died; '
            'this is that number: 20 - 16 overhead',
      );
    });

    test('a short-named radio is left with one byte in a channel', () {
      expect(
        maxChannelMessageBytes('WSMJ898', maxFrameBytes: unknownMtuFrameBudget),
        1,
        reason:
            'the "<name>: " prefix eats the frame budget: 20 - 10 overhead - 9 '
            'prefix leaves 1',
      );
    });

    test('any radio name of 8 characters or more reaches zero', () {
      expect(
        maxChannelMessageBytes(
          'WSMJ898-OBS-HV4',
          maxFrameBytes: unknownMtuFrameBudget,
        ),
        0,
        reason:
            'a longer name pushes the frame budget negative and _minPositive '
            'clamps to 0, so not one character is accepted',
      );
      expect(
        maxChannelMessageBytes(null, maxFrameBytes: unknownMtuFrameBudget),
        0,
      );
    });
  });

  group('budget on a transport with a full frame', () {
    test('a DM composer gets the frame budget minus overhead', () {
      // 172 frame - 16 overhead = 156, just under the 160 payload cap.
      expect(maxContactMessageBytes(), 156);
    });

    test('a channel composer stays usable', () {
      expect(maxChannelMessageBytes('WSMJ898'), greaterThan(100));
    });

    test('a healthy negotiated BLE MTU restores a usable budget', () {
      // A typical Windows/Android negotiation lands around 244-517; 185 is the
      // value the app requests on Android. 185 - 3 = 182 writable, which is
      // above maxFrameSize, so the budget is the same as a full frame.
      expect(maxContactMessageBytes(maxFrameBytes: 172), 156);
      expect(
        maxChannelMessageBytes('WSMJ898', maxFrameBytes: 172),
        greaterThan(100),
      );
    });
  });

  /// The guard #684 adds. These are the assertions that were left out of this
  /// file while it lived on a throwaway branch, because the behaviour they
  /// describe did not exist yet.
  group('the composer guard recognises an unusable budget (#684)', () {
    test('a zero budget is not usable', () {
      // The literal #592 symptom: every keystroke rejected, field looks alive.
      expect(isComposerBudgetUsable(0), isFalse);
    });

    test('the degenerate #592 budgets are all caught', () {
      // DM 4 and channel 1 at the unknown-MTU floor. A field that accepts four
      // characters is as misleading as one that accepts none, so the guard has
      // to catch the near-misses, not just zero.
      expect(
        isComposerBudgetUsable(
          maxContactMessageBytes(maxFrameBytes: unknownMtuFrameBudget),
        ),
        isFalse,
        reason: 'the 4-byte DM budget must trigger the notice',
      );
      expect(
        isComposerBudgetUsable(
          maxChannelMessageBytes(
            'WSMJ89',
            maxFrameBytes: unknownMtuFrameBudget,
          ),
        ),
        isFalse,
        reason: 'the 1-byte channel budget must trigger the notice',
      );
    });

    test('the threshold boundary is exact', () {
      expect(isComposerBudgetUsable(minUsableComposerBytes - 1), isFalse);
      expect(isComposerBudgetUsable(minUsableComposerBytes), isTrue);
    });

    test('a healthy link does NOT trigger the notice', () {
      // The negative test: the guard must stay invisible on a working link, or
      // it becomes noise that trains users to ignore it.
      expect(isComposerBudgetUsable(maxContactMessageBytes()), isTrue);
      expect(isComposerBudgetUsable(maxChannelMessageBytes('WSMJ898')), isTrue);
      // And at the MTU actually measured on hardware: 247 on Android, 176 on
      // Windows once the vendored plugin reports it (#686).
      expect(
        isComposerBudgetUsable(
          maxChannelMessageBytes('WSMJ898', maxFrameBytes: 247 - 3),
        ),
        isTrue,
      );
      expect(
        isComposerBudgetUsable(
          maxChannelMessageBytes('WSMJ898', maxFrameBytes: 176 - 3),
        ),
        isTrue,
      );
    });
  });
}
