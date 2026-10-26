import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';

// #773 (B2 of #755): the client's own settings frames against the fake.

int _u32(List<int> b, int at) => ByteData.sublistView(
  Uint8List.fromList(b),
  at,
  at + 4,
).getUint32(0, Endian.little);

Uint8List _selfInfo(FakeRadio r) =>
    r.handle(Uint8List.fromList([fwCmdAppStart, 0, 0, 0, 0, 0, 0, 0])).single;

Uint8List _deviceInfo(FakeRadio r) =>
    r.handle(Uint8List.fromList([fwCmdDeviceQuery, 3])).single;

void main() {
  for (final profile in [FakeRadioProfile.offband, FakeRadioProfile.stock]) {
    group('${profile().name} radio settings', () {
      test('cmd 11 changes what SELF_INFO reports', () {
        final r = FakeRadio(profile: profile());
        expect(r.handle(buildSetRadioParamsFrame(909750, 500000, 10, 5)), [
          [fwRespOk],
        ]);
        final s = _selfInfo(r);
        expect(_u32(s, 48), 909750);
        expect(_u32(s, 52), 500000);
        expect(s[56], 10);
        expect(s[57], 5);
      });

      test('cmd 11 refuses out-of-range values and changes nothing', () {
        final r = FakeRadio(profile: profile());
        for (final bad in [
          buildSetRadioParamsFrame(909750, 600000, 10, 5), // bw > 500 kHz
          buildSetRadioParamsFrame(100000, 62500, 10, 5), // freq < 150 MHz
          buildSetRadioParamsFrame(909750, 62500, 13, 5), // sf > 12
          buildSetRadioParamsFrame(909750, 62500, 10, 4), // cr < 5
        ]) {
          expect(r.handle(bad), [
            [fwRespErr, fwErrIllegalArg],
          ]);
        }
        expect(_u32(_selfInfo(r), 48), 910525);
      });

      test('client repeat only on an allowed frequency', () {
        final r = FakeRadio(profile: profile());
        expect(
          r.handle(
            buildSetRadioParamsFrame(910525, 62500, 7, 5, clientRepeat: true),
          ),
          [
            [fwRespErr, fwErrIllegalArg],
          ],
        );
        expect(
          r.handle(
            buildSetRadioParamsFrame(918000, 250000, 11, 8, clientRepeat: true),
          ),
          [
            [fwRespOk],
          ],
        );
        expect(_deviceInfo(r)[80], 1);
      });

      test('cmd 12 accepts -9 to max TX power', () {
        final r = FakeRadio(profile: profile());
        expect(r.handle(buildSetRadioTxPowerFrame(-9)), [
          [fwRespOk],
        ]);
        expect(_selfInfo(r)[2], (-9) & 0xFF);
        expect(r.handle(buildSetRadioTxPowerFrame(-10)), [
          [fwRespErr, fwErrIllegalArg],
        ]);
        expect(r.handle(buildSetRadioTxPowerFrame(23)), [
          [fwRespErr, fwErrIllegalArg],
        ]);
        expect(r.handle(buildSetRadioTxPowerFrame(22)), [
          [fwRespOk],
        ]);
      });

      test('cmd 61 sets path hash mode 0-2, shown in DEVICE_INFO', () {
        final r = FakeRadio(profile: profile());
        expect(r.handle(buildSetPathHashModeFrame(1)), [
          [fwRespOk],
        ]);
        expect(_deviceInfo(r)[81], 1);
        // The client clamps; a raw mode 3 is refused by the radio.
        expect(r.handle(Uint8List.fromList([fwCmdSetPathHashMode, 0, 3])), [
          [fwRespErr, fwErrIllegalArg],
        ]);
        // A non-zero second byte isn't this command at all.
        expect(r.handle(Uint8List.fromList([fwCmdSetPathHashMode, 1, 1])), [
          [fwRespErr, fwErrUnsupportedCmd],
        ]);
      });

      test('cmd 38 sets the other params SELF_INFO reports', () {
        final r = FakeRadio(profile: profile());
        expect(r.handle(buildSetOtherParamsFrame(0x15, 2, 1)), [
          [fwRespOk],
        ]);
        final s = _selfInfo(r);
        expect(s[44], 1); // multi acks
        expect(s[45], 2); // advert location policy
        expect(s[46], 0x15); // telemetry modes
        expect(s[47], 1); // manual add contacts
      });
    });
  }
}
