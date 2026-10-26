import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';
import '../support/fake_radio/fake_radio_trace.dart';
import '../support/fake_radio/fake_remote_node.dart';

// #777: Epic B verification. Every B behavior, driven by the client's own
// frame builders, under the Offband and stock companion profiles.

void main() {
  final alpha = FakeContact.keyed(0x11, 'Alpha');
  final rpt = FakeContact.keyed(0x51, 'Rpt', type: fwAdvTypeRepeater);

  for (final profile in [FakeRadioProfile.offband, FakeRadioProfile.stock]) {
    group('${profile().name} companion', () {
      late FakeRadio radio;
      late List<Uint8List> pushes;

      setUp(() {
        radio = FakeRadio(
          profile: profile(),
          seed: FakeRadioSeed(
            contacts: [alpha],
            channels: [FakeChannel(index: 0, name: 'Public')],
          ),
        );
        radio.addRemoteNode(FakeRemoteNode(contact: rpt));
        pushes = [];
        radio.pushes.listen(pushes.add);
      });

      test('B1: DM -> SENT -> ACK; channel send; incoming DM and channel', () {
        final sent = radio
            .handle(buildSendTextMsgFrame(alpha.publicKey, 'hi'))
            .single;
        expect(sent[0], fwRespSent);
        radio.clock.advance(const Duration(seconds: 1));
        expect(pushes.last[0], fwPushSendConfirmed);
        expect(radio.handle(buildSendChannelTextMsgFrame(0, 'all')), [
          [fwRespOk],
        ]);
        radio
          ..receiveDirect(alpha, 'in')
          ..receiveChannel(0, 'Alpha: in');
        expect(radio.offlineQueue.map((f) => f[0]), [
          fwRespContactMsgRecvV3,
          fwRespChannelMsgRecvV3,
        ]);
      });

      test('B2: radio settings land in SELF_INFO', () {
        radio
          ..handle(buildSetRadioParamsFrame(909750, 500000, 10, 5))
          ..handle(buildSetRadioTxPowerFrame(14))
          ..handle(buildSetPathHashModeFrame(1));
        expect(
          [radio.freqKhz, radio.bwHz, radio.txPowerDbm, radio.pathHashMode],
          [909750, 500000, 14, 1],
        );
      });

      test('B3: login and a CLI round trip to a remote node', () {
        radio.handle(buildSendLoginFrame(rpt.publicKey, 'password'));
        radio.clock.advance(const Duration(seconds: 1));
        expect(pushes.last[0], fwPushLoginSuccess);
        radio.offlineQueue.clear();
        radio.handle(buildSendCliCommandFrame(rpt.publicKey, 'get radio'));
        radio.clock.advance(const Duration(seconds: 1));
        expect(
          utf8.decode(radio.offlineQueue.single.sublist(16)),
          '> 910.525,62.5,7,5',
        );
      });

      test('B4: a scripted ERR, a late reply, a lost ACK', () {
        radio
          ..failNext(fwCmdGetBattAndStorage)
          ..delayNext(fwCmdGetAutoAddConfig, const Duration(seconds: 3))
          ..acksToDrop = 1;
        expect(
          radio.handle(Uint8List.fromList([fwCmdGetBattAndStorage]))[0][0],
          fwRespErr,
        );
        expect(
          radio.handle(Uint8List.fromList([fwCmdGetAutoAddConfig])),
          isEmpty,
        );
        radio.handle(buildSendTextMsgFrame(alpha.publicKey, 'lost'));
        radio.clock.advance(const Duration(seconds: 3));
        expect(pushes.map((p) => p[0]), [fwRespAutoAddConfig]);
      });

      test('B5: a recording of this companion replays exactly', () {
        final trace = FakeRadioTrace.parse(
          FakeRadioTrace.record(radio, captureRequests()).toJson(),
        );
        expect(trace.replay(trace.radio()), isEmpty);
      });
    });
  }
}
