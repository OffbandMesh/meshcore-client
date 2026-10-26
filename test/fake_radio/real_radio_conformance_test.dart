import 'package:flutter_test/flutter_test.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_manifest.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_trace.dart';

// #784 (D2 of #755): the fake against real radios. Each trace was captured
// from hardware with tool/fake_radio/capture_trace.py and anonymized with
// anonymize_trace.py. A fake seeded from a trace must give every reply the
// radio gave, byte for byte, and the pinned profile must be the firmware the
// radio says it runs.

class _Radio {
  const _Radio(this.file, this.pinned, this.manifest);

  final String file;
  final FakeRadioProfile Function() pinned;
  final FakeRadioManifest Function() manifest;
}

final _radios = [
  _Radio(
    'stock-companion-v1.18.0-heltec-v4',
    FakeRadioProfile.stock,
    FakeRadioManifest.pinnedStock,
  ),
  _Radio(
    'offband-v1.5.0-beta7-rak4631',
    FakeRadioProfile.offband,
    FakeRadioManifest.pinnedOffband,
  ),
];

void main() {
  for (final r in _radios) {
    group(r.file, () {
      final trace = FakeRadioTrace.load(
        'test/fake_radio/traces/${r.file}.json',
      );

      test('every request has its own answer in the capture', () {
        // A capture that misfiles a late reply under the next step would
        // still replay clean, so check the capture itself.
        for (final (i, s) in trace.steps.indexed) {
          // GET_CONTACTS and the Offband block LIST stream several frames.
          final streams =
              s.request[0] == fwCmdGetContacts ||
              (s.request[0] == fwOffbandBlock && trace.profile().offband);
          if (streams) {
            expect(s.replies, isNotEmpty, reason: 'step $i');
          } else {
            expect(s.replies, hasLength(1), reason: 'step $i');
          }
        }
      });

      test('a fake seeded from it gives every reply the radio gave', () {
        expect(trace.replay(trace.radio()), isEmpty);
      });

      test('the pinned profile is the firmware the radio reports', () {
        final real = trace.profile();
        final pinned = r.pinned();
        expect(real.offband, pinned.offband);
        expect(real.firmwareVerCode, pinned.firmwareVerCode);
        // 82 bytes on stock, 87 with the Offband tail.
        expect(
          FakeRadio(profile: pinned).deviceInfoFrame().length,
          trace.steps.first.replies.single.length,
        );
        if (pinned.offband) {
          expect(real.versionString, pinned.versionString);
        } else {
          // Stock builds append the commit: "v1.18.0-81dbae5".
          final m = r.manifest();
          expect(
            real.versionString,
            '${pinned.versionString}-${m.commit.substring(0, 7)}',
          );
        }
        // The pinned bits are the ones every board sets; a board may add
        // its own (this RAK4631 adds BUTTON_MATRIX and INDICATORS).
        expect(real.offbandCaps & pinned.offbandCaps, pinned.offbandCaps);
        expect(real.offbandCaps2 & pinned.offbandCaps2, pinned.offbandCaps2);
      });

      test('the trace is anonymized', () {
        final seed = trace.seed();
        expect(seed.name, 'Trace Radio');
        expect(
          seed.contacts.every(
            (c) => RegExp(
              r'^(Contact|Repeater|Room|Sensor|Node|Unsent) \d+$',
            ).hasMatch(c.name),
          ),
          isTrue,
        );
        expect(
          seed.channels.every(
            (c) =>
                c.name.isEmpty ||
                RegExp(r'^(Public|Channel \d+)$').hasMatch(c.name),
          ),
          isTrue,
        );
      });
    });
  }
}
