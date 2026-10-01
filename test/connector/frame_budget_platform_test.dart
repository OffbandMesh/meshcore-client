import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

/// Regression lock for the frame budget, per platform.
///
/// This one getter decides the composer's byte budget everywhere, and it had
/// collapsed that budget to zero on three of the five platforms before anyone
/// noticed, each time surfacing as a user reporting "the keyboard doesn't
/// respond":
///
///   Windows (#686) - the WinRT plugin never created a GattSession, so no MTU
///                    was ever reported and mtuNow stayed on its 23 default.
///   Linux   (#717) - the plugin's onMtuChanged returned Stream.empty().
///   Web     (#718) - Web Bluetooth exposes no MTU at all, so the BLE floor
///                    applied forever.
///
/// None of those were caught by a test, because nothing exercised this
/// function. They were caught by users, two months and three platforms apart.
/// These cases exist so a regression is a red build instead of a bug report.
int _budget({
  MeshCoreTransportType transport = MeshCoreTransportType.bluetooth,
  bool isWeb = false,
  int mtuNow = 0,
}) => MeshCoreConnector.resolveFrameBudget(
  transport: transport,
  isWeb: isWeb,
  mtuNow: mtuNow,
);

void main() {
  group('non-BLE transports are never floored', () {
    test('usb gets the full frame', () {
      expect(_budget(transport: MeshCoreTransportType.usb), maxFrameSize);
    });

    test('tcp gets the full frame', () {
      expect(_budget(transport: MeshCoreTransportType.tcp), maxFrameSize);
    });

    test('a wired transport ignores a bogus MTU entirely', () {
      expect(
        _budget(transport: MeshCoreTransportType.usb, mtuNow: 23),
        maxFrameSize,
      );
    });
  });

  group('web BLE is exempt from the floor (#718)', () {
    // The branch that cannot be reached any other way: kIsWeb is a
    // compile-time constant, so without the pure function this is untestable.
    test('web gets the full frame even with no MTU reported', () {
      expect(_budget(isWeb: true, mtuNow: 0), maxFrameSize);
    });

    test('web gets the full frame even at the 23-byte ATT default', () {
      expect(_budget(isWeb: true, mtuNow: 23), maxFrameSize);
    });

    test('a web budget leaves BOTH composers usable', () {
      // The actual regression: this is what was 0 before #718.
      final budget = _budget(isWeb: true, mtuNow: 23);
      expect(
        isComposerBudgetUsable(
          maxChannelMessageBytes('KB9QDI-JOE', maxFrameBytes: budget),
        ),
        isTrue,
      );
      expect(
        isComposerBudgetUsable(maxContactMessageBytes(maxFrameBytes: budget)),
        isTrue,
      );
    });
  });

  group('native BLE keeps the write-safety floor (#395)', () {
    test('no device reported yields the floor, never the full frame', () {
      // Must NOT be maxFrameSize: defaulting an unknown link to the largest
      // size would authorize an oversized write, which is what the floor is
      // for. The floor is correct here even though it is what made the
      // composer unusable; the fix was reporting the MTU, not removing this.
      expect(_budget(mtuNow: 0), 20);
    });

    test('the 23-byte ATT minimum yields the floor', () {
      expect(_budget(mtuNow: 23), 20);
    });

    test('a negotiated MTU is honoured minus the 3-byte ATT header', () {
      expect(_budget(mtuNow: 100), 97);
    });

    test('a large MTU is capped at the frame size', () {
      expect(_budget(mtuNow: 517), maxFrameSize);
    });

    test('never returns below the floor for an absurdly small MTU', () {
      expect(_budget(mtuNow: 5), 20);
    });
  });

  group('the MTUs actually measured on hardware leave the composer usable', () {
    // Pinning the real numbers, so a regression that silently reintroduces the
    // floor on a healthy link fails here rather than in someone's chat window.
    for (final probe in <({String platform, int mtu})>[
      (platform: 'Android', mtu: 247),
      (platform: 'Windows after #686', mtu: 176),
    ]) {
      test('${probe.platform} (MTU ${probe.mtu})', () {
        final budget = _budget(mtuNow: probe.mtu);
        expect(budget, maxFrameSize);
        expect(
          isComposerBudgetUsable(
            maxChannelMessageBytes('KB9QDI-JOE', maxFrameBytes: budget),
          ),
          isTrue,
          reason: 'a healthy link must leave a usable channel composer',
        );
      });
    }
  });

  group('the exact failure users reported is still reproducible', () {
    test('an unreported MTU collapses the channel composer to zero', () {
      // Not a fix to preserve, a fact to keep visible: when the MTU is
      // genuinely unknown the budget IS unusable, which is why #684's guard
      // has to exist and why reporting the MTU was the real fix.
      final budget = _budget(mtuNow: 0);
      expect(maxChannelMessageBytes('KB9QDI-JOE', maxFrameBytes: budget), 0);
      expect(maxContactMessageBytes(maxFrameBytes: budget), 4);
    });
  });
}
