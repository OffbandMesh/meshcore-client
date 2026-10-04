import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fake_radio/fake_clock.dart';
import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_profile.dart';
import '../support/fake_radio/fake_radio_seed.dart';

Uint8List _cmd(List<int> b) => Uint8List.fromList(b);

int _u32(Uint8List b, int at) =>
    ByteData.sublistView(b, at, at + 4).getUint32(0, Endian.little);

Uint8List _le32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

String _cstr(Uint8List b, int at, int width) {
  final field = b.sublist(at, at + width);
  final end = field.indexOf(0);
  return utf8.decode(end < 0 ? field : field.sublist(0, end));
}

void main() {
  group('device info (#601)', () {
    test('Offband: 87 bytes with the capability tail', () {
      final f = FakeRadio().handle(_cmd([fwCmdDeviceQuery, 4])).single;
      expect(f[0], fwRespDeviceInfo);
      expect(f[1], 22);
      expect(f[2], 175); // 350 / 2
      expect(f[3], 8);
      expect(_cstr(f, 8, 12), '1 Oct 2026');
      expect(_cstr(f, 20, 40), 'Fake Radio Board');
      expect(_cstr(f, 60, 20), '1.5.0-1.17.1');
      expect(f.length, 87);
      expect(f[82], 0x22); // BLOCK | CAPLOG
      expect(f[84], 0x08); // PKT_HASH
    });

    test('stock: ends after path hash mode (82 bytes), no Offband tail', () {
      final f = FakeRadio(
        profile: FakeRadioProfile.stockDefault,
      ).handle(_cmd([fwCmdDeviceQuery, 4])).single;
      expect(f[1], 13);
      expect(_cstr(f, 60, 20), 'v1.17.1');
      expect(f.length, 82);
    });
  });

  test('self info carries the seeded identity and radio settings', () {
    final radio = FakeRadio(
      seed: FakeRadioSeed(name: 'Base', freqKhz: 909750, bwHz: 500000, sf: 10),
    );
    final f = radio.handle(_cmd([fwCmdAppStart, ...List.filled(7, 0)])).single;
    expect(f[0], fwRespSelfInfo);
    expect(f.sublist(4, 36), radio.seed.publicKey);
    expect(_u32(f, 48), 909750);
    expect(_u32(f, 52), 500000);
    expect(f[56], 10);
    expect(f[57], 5);
    expect(utf8.decode(f.sublist(58)), 'Base');
  });

  group('contacts', () {
    final radio = FakeRadio(
      seed: FakeRadioSeed(
        contacts: [
          FakeContact.keyed(0x11, 'Alpha', lastmod: 100),
          FakeContact.keyed(0x22, 'Bravo', lastmod: 200),
        ],
      ),
    );

    test('start (total), one frame per contact, end (latest lastmod)', () {
      final out = radio.handle(_cmd([fwCmdGetContacts]));
      expect(out.map((f) => f[0]), [
        fwRespContactsStart,
        fwRespContact,
        fwRespContact,
        fwRespEndOfContacts,
      ]);
      expect(_u32(out.first, 1), 2);
      expect(out[1].length, 148);
      expect(_cstr(out[1], 100, 32), 'Alpha');
      expect(_u32(out.last, 1), 200);
    });

    test("'since' filters the list but START still reports the total", () {
      final out = radio.handle(_cmd([fwCmdGetContacts, ..._le32(100)]));
      expect(out.length, 3);
      expect(_u32(out.first, 1), 2);
      expect(_cstr(out[1], 100, 32), 'Bravo');
    });
  });

  test('channels: info for a seeded slot, NOT_FOUND for an empty one', () {
    final radio = FakeRadio(
      seed: FakeRadioSeed(channels: [FakeChannel(index: 0, name: 'Public')]),
    );
    final info = radio.handle(_cmd([fwCmdGetChannel, 0])).single;
    expect(info[0], fwRespChannelInfo);
    expect(_cstr(info, 2, 32), 'Public');
    expect(info.length, 50);
    expect(radio.handle(_cmd([fwCmdGetChannel, 1])).single, [
      fwRespErr,
      fwErrNotFound,
    ]);
  });

  test('message queue drains, then NO_MORE_MESSAGES', () {
    final radio = FakeRadio()..offlineQueue.add(_cmd([0x10, 1, 2]));
    expect(radio.handle(_cmd([fwCmdSyncNextMessage])).single, [0x10, 1, 2]);
    expect(radio.handle(_cmd([fwCmdSyncNextMessage])).single, [
      fwRespNoMoreMessages,
    ]);
  });

  group('device time', () {
    test('Offband accepts a time in either direction (#607)', () {
      final radio = FakeRadio();
      expect(radio.handle(_cmd([fwCmdSetDeviceTime, ..._le32(1000)])).single, [
        fwRespOk,
      ]);
      expect(radio.clock.epochSeconds, 1000);
    });

    test('stock refuses a time earlier than its clock', () {
      final radio = FakeRadio(profile: FakeRadioProfile.stockDefault);
      expect(radio.handle(_cmd([fwCmdSetDeviceTime, ..._le32(1000)])).single, [
        fwRespErr,
        fwErrIllegalArg,
      ]);
      expect(
        radio.handle(_cmd([fwCmdSetDeviceTime, ..._le32(1790000500)])).single,
        [fwRespOk],
      );
    });
  });

  test('battery, custom vars and auto-add replies', () {
    final radio = FakeRadio(
      seed: FakeRadioSeed(customVars: {'gps': '1'}, autoAddConfig: 3),
    );
    final batt = radio.handle(_cmd([fwCmdGetBattAndStorage])).single;
    expect(batt.length, 11);
    expect(ByteData.sublistView(batt).getUint16(1, Endian.little), 4100);
    expect(
      utf8.decode(radio.handle(_cmd([fwCmdGetCustomVars])).single.sublist(1)),
      'gps:1',
    );
    expect(radio.handle(_cmd([fwCmdGetAutoAddConfig])).single, [
      fwRespAutoAddConfig,
      3,
      0,
    ]);
  });

  test('an unknown command is UNSUPPORTED, and every command is logged', () {
    final radio = FakeRadio();
    expect(radio.handle(_cmd([0x7E])).single, [fwRespErr, fwErrUnsupportedCmd]);
    expect(radio.received.single, [0x7E]);
  });

  test('same seed, same replies', () {
    List<List<int>> run() {
      final radio = FakeRadio(
        seed: FakeRadioSeed(contacts: [FakeContact.keyed(0x11, 'Alpha')]),
      );
      return [
        for (final c in [
          [fwCmdDeviceQuery, 4],
          [fwCmdAppStart, ...List.filled(7, 0)],
          [fwCmdGetContacts],
        ])
          for (final f in radio.handle(_cmd(c))) f.toList(),
      ];
    }

    expect(run(), run());
  });

  group('fake clock', () {
    test('runs scheduled work in due order, only when advanced', () {
      final clock = FakeClock(epochSeconds: 100);
      final ran = <String>[];
      clock
        ..schedule(const Duration(seconds: 2), () => ran.add('b'))
        ..schedule(const Duration(seconds: 1), () => ran.add('a'));
      expect(ran, isEmpty);
      clock.advance(const Duration(seconds: 1));
      expect(ran, ['a']);
      clock.advance(const Duration(seconds: 5));
      expect(ran, ['a', 'b']);
      expect(clock.epochSeconds, 106);
    });

    test('work scheduled while advancing runs if it falls due', () {
      final clock = FakeClock();
      final ran = <int>[];
      clock.schedule(const Duration(seconds: 1), () {
        ran.add(1);
        clock.schedule(const Duration(seconds: 1), () => ran.add(2));
      });
      clock.advance(const Duration(seconds: 3));
      expect(ran, [1, 2]);
    });
  });
}
