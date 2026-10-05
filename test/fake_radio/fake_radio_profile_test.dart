import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_codes.dart';
import '../support/fake_radio/fake_radio_manifest.dart';
import '../support/fake_radio/fake_radio_profile.dart';

Uint8List _cmd(List<int> b) => Uint8List.fromList(b);

void main() {
  group('pinned manifests (#769)', () {
    test('Offband: offband-v1.5.0-beta7 on MeshCore v1.17.0, code 22', () {
      final m = FakeRadioManifest.pinnedOffband();
      expect(m.isOffband, isTrue);
      expect(m.ref, 'offband-v1.5.0-beta7');
      expect(m.firmwareVerCode, 22);
      expect(m.firmwareVersion, 'v1.17.0');
      expect(m.deviceInfoVersion, '1.5.0-1.17.0');
      expect(m.offbandCaps['OFFBAND_CAP_CAPLOG'], 0x20);
      expect(m.offbandCommands['CMD_OFFBAND_PKT_HASH'], 0xC6);
    });

    test('stock: companion-v1.17.1, code 13, no Offband anything', () {
      final m = FakeRadioManifest.pinnedStock();
      expect(m.isOffband, isFalse);
      expect(m.firmwareVerCode, 13);
      expect(m.deviceInfoVersion, 'v1.17.1');
      expect(m.offbandCaps, isEmpty);
      expect(m.offbandCommands, isEmpty);
    });

    test('a wrong format or a newer format_version is refused', () {
      expect(
        () => FakeRadioManifest.parse(jsonEncode({'format': 'x'})),
        throwsFormatException,
      );
      expect(
        () => FakeRadioManifest.parse(
          jsonEncode({
            'format': 'offband-protocol-manifest',
            'format_version': 2,
          }),
        ),
        throwsFormatException,
      );
    });

    test('a capability the manifest lacks fails loudly, never reads as 0', () {
      final m = FakeRadioManifest.pinnedOffband();
      expect(() => m.capsOf(['OFFBAND_CAP_NOPE']), throwsStateError);
      expect(
        () => FakeRadioProfile.fromManifest(m, caps: ['OFFBAND_CAP_NOPE']),
        throwsStateError,
      );
    });
  });

  group('profiles', () {
    test('Offband defaults to the bits every companion sets', () {
      final p = FakeRadioProfile.offband();
      expect(p.offbandCaps, 0x02 | 0x20); // BLOCK | CAPLOG
      expect(p.offbandCaps2, 0x08); // PKT_HASH
    });

    test('board bits can be named', () {
      final p = FakeRadioProfile.fromManifest(
        FakeRadioManifest.pinnedOffband(),
        caps: ['OFFBAND_CAP_BLOCK', 'OFFBAND_CAP_FEM_LNA'],
        caps2: ['OFFBAND_CAP2_NOTIFY_SCOPE'],
      );
      expect(p.offbandCaps, 0x06);
      expect(p.offbandCaps2, 0x01);
    });

    test('stock rejects every Offband command as unsupported', () {
      final radio = FakeRadio(profile: FakeRadioProfile.stock());
      for (final code in [
        fwOffbandConfig,
        fwOffbandGps,
        fwOffbandBlock,
        fwOffbandPktHash,
      ]) {
        expect(radio.handle(_cmd([code, fwBlockList])).single, [
          fwRespErr,
          fwErrUnsupportedCmd,
        ]);
      }
    });
  });

  group('Offband commands', () {
    final key = List<int>.filled(fwPubKeySize, 0x42);
    final other = List<int>.filled(fwPubKeySize, 0x43);

    test('block: add dedups, remove swaps, list streams start/keys/end', () {
      final radio = FakeRadio();
      expect(radio.handle(_cmd([fwOffbandBlock, fwBlockAdd, ...key])).single, [
        fwOffbandBlock,
        fwBlockAdd,
        1,
      ]);
      // A repeat is still OK (BlockStore dedup).
      expect(
        radio.handle(_cmd([fwOffbandBlock, fwBlockAdd, ...key])).single[2],
        1,
      );
      radio.handle(_cmd([fwOffbandBlock, fwBlockAdd, ...other]));
      final list = radio.handle(_cmd([fwOffbandBlock, fwBlockList]));
      expect(list.first, [fwOffbandBlock, fwBlockList, 0xFF, 2]);
      expect(list[1].sublist(3), key);
      expect(list.last, [fwOffbandBlock, fwBlockList, 0xFE]);

      expect(
        radio.handle(_cmd([fwOffbandBlock, fwBlockRemove, ...key])).single[2],
        1,
      );
      expect(radio.blockedKeys.single, other);
      expect(
        radio.handle(_cmd([fwOffbandBlock, fwBlockRemove, ...key])).single[2],
        0,
      );
    });

    test('GPS status reply is "enabled=N " plus board text, NUL-ended', () {
      final f = FakeRadio().handle(_cmd([fwOffbandGps])).single;
      expect(f[0], fwOffbandGps);
      expect(f.last, 0);
      expect(utf8.decode(f.sublist(1, f.length - 1)), 'enabled=0 detected=0');
    });

    test('packet hash: unknown key, or malformed when not 7 bytes', () {
      final radio = FakeRadio();
      expect(
        radio.handle(_cmd([fwOffbandPktHash, fwPktHashGet, 1, 2, 3, 4, 0])),
        [
          [fwOffbandPktHash, fwPktHashErr, fwPktHashErrUnknownKey],
        ],
      );
      expect(radio.handle(_cmd([fwOffbandPktHash, fwPktHashGet, 1])).single, [
        fwOffbandPktHash,
        fwPktHashErr,
        fwPktHashErrMalformed,
      ]);
    });

    test('commands needing unadvertised bits are unsupported', () {
      final radio = FakeRadio();
      for (final code in [
        fwOffbandConfig,
        fwOffbandFemLna,
        fwOffbandDeviceUi,
      ]) {
        expect(radio.handle(_cmd([code, 0])).single, [
          fwRespErr,
          fwErrUnsupportedCmd,
        ]);
      }
    });
  });
}
