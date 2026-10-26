import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';
import '../support/fake_radio/fake_radio_trace.dart';

// #776 (B5 of #755): record a session, seed a fake from it, replay it.
// Real-radio traces arrive at D1 (#783/#784); here the recording is the fake's.

FakeRadio _richRadio({FakeRadioProfile? profile}) {
  final routed = FakeContact(
    publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
    name: 'Routed',
    type: fwAdvTypeRepeater,
    outPathLength: 2,
    outPath: Uint8List.fromList([0xAB, 0xCD]),
    latE6: 39100000,
    lonE6: -84500000,
    lastmod: 1790000500,
  );
  return FakeRadio(
    profile: profile,
    seed: FakeRadioSeed(
      name: 'Base Station',
      freqKhz: 909750,
      bwHz: 500000,
      sf: 10,
      latE6: 39200000,
      lonE6: -84400000,
      customVars: {'gps': '1'},
      autoAddConfig: 5,
      autoAddMaxHops: 3,
      contacts: [FakeContact.keyed(0x11, 'Alpha'), routed],
      channels: [
        FakeChannel(index: 0, name: 'Public'),
        FakeChannel(
          index: 2,
          name: '#oki',
          secret: Uint8List.fromList(List<int>.filled(16, 0x5A)),
        ),
      ],
    ),
  )..blockedKeys.add(Uint8List.fromList(List<int>.filled(32, 0x99)));
}

void main() {
  for (final profile in [FakeRadioProfile.offband, FakeRadioProfile.stock]) {
    test(
      '${profile().name}: a fake seeded from a recording replays it exactly',
      () {
        final recording = FakeRadioTrace.record(
          _richRadio(profile: profile()),
          captureRequests(),
        );
        // Through the file format, as a real capture would arrive.
        final trace = FakeRadioTrace.parse(recording.toJson());
        expect(trace.replay(trace.radio()), isEmpty);
      },
    );
  }

  test('a recorded reply the fake disagrees with is reported, by step', () {
    final trace = FakeRadioTrace.record(_richRadio(), captureRequests());
    // The unknown-command reply: nothing in the seed comes from it, so the
    // fake can't absorb the change.
    final step = trace.steps.indexWhere((s) => s.request[0] == 0x7E);
    trace.steps[step].replies[0][1] = fwErrBadState;
    final diffs = trace.replay(trace.radio());
    expect(diffs, hasLength(1));
    expect(diffs.single, startsWith('step $step '));
  });

  test('a missing or extra reply is reported', () {
    final trace = FakeRadioTrace.record(_richRadio(), captureRequests());
    trace.steps.first.replies.add(Uint8List.fromList([fwRespOk]));
    expect(trace.replay(trace.radio()).single, contains('recorded 2'));
  });

  test(
    "bytes past a channel name's NUL are firmware leftovers, not a diff",
    () {
      final trace = FakeRadioTrace.record(_richRadio(), captureRequests());
      final info = trace.steps
          .expand((s) => s.replies)
          .firstWhere((r) => r[0] == fwRespChannelInfo);
      info[2 + 'Public'.length + 3] = 0xEE; // stale byte from an earlier frame
      expect(trace.replay(trace.radio()), isEmpty);
    },
  );

  test('the profile comes from what DEVICE_INFO recorded', () {
    final offband = FakeRadioTrace.record(_richRadio(), captureRequests());
    final p = offband.profile();
    expect(p.offband, isTrue);
    expect(p.firmwareVerCode, 22);
    expect(p.versionString, '1.5.0-1.17.0');
    expect(p.offbandCaps, 0x22);
    expect(p.deviceInfoTailBytes, 5);

    final stock = FakeRadioTrace.record(
      _richRadio(profile: FakeRadioProfile.stock()),
      captureRequests(),
    ).profile();
    expect(stock.offband, isFalse);
    expect(stock.deviceInfoTailBytes, 0);
  });

  test('an older Offband build with a shorter tail replays too', () {
    final old = FakeRadioProfile(
      name: 'offband-v16',
      firmwareVerCode: 16,
      versionString: '1.2.0-1.15.0',
      offband: true,
      offbandCaps: 0x02,
      deviceInfoTailBytes: 2, // caps + FEM state only
    );
    final trace = FakeRadioTrace.record(
      _richRadio(profile: old),
      captureRequests(),
    );
    expect(trace.steps.first.replies.single.length, 84);
    expect(trace.replay(trace.radio()), isEmpty);
  });
}
