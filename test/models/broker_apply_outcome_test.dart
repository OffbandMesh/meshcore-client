// Honest-apply classifier (#89). A firmware build can ACK a broker
// enable/disable as success but not apply it (HV4 desync,
// meshcore-firmware#179). After a toggle/save the UI re-reads the slot and
// compares to what it asked for; this classifier turns (intended, re-read) into
// the outcome the UI reports. It treats every device identically, it only ever
// reflects the re-read, never assuming the change took.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/observer_config.dart';

void main() {
  group('BrokerConfig.classifyApply', () {
    test('enable the device confirms -> applied', () {
      expect(
        BrokerConfig.classifyApply(intendedEnabled: true, actualEnabled: true),
        BrokerApplyOutcome.applied,
      );
    });

    test('disable the device confirms -> applied', () {
      expect(
        BrokerConfig.classifyApply(
          intendedEnabled: false,
          actualEnabled: false,
        ),
        BrokerApplyOutcome.applied,
      );
    });

    test(
      'disable ACKed but re-read still enabled -> notApplied (the HV4 bug)',
      () {
        expect(
          BrokerConfig.classifyApply(
            intendedEnabled: false,
            actualEnabled: true,
          ),
          BrokerApplyOutcome.notApplied,
        );
      },
    );

    test('enable ACKed but re-read still disabled -> notApplied', () {
      expect(
        BrokerConfig.classifyApply(intendedEnabled: true, actualEnabled: false),
        BrokerApplyOutcome.notApplied,
      );
    });

    test('re-read failed (null) -> unverified, whatever the intent', () {
      expect(
        BrokerConfig.classifyApply(intendedEnabled: true, actualEnabled: null),
        BrokerApplyOutcome.unverified,
      );
      expect(
        BrokerConfig.classifyApply(intendedEnabled: false, actualEnabled: null),
        BrokerApplyOutcome.unverified,
      );
    });
  });
}
