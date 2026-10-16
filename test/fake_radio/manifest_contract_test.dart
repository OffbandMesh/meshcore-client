import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

import '../support/fake_radio/fake_radio.dart';
import '../support/fake_radio/fake_radio_manifest.dart';
import '../support/fake_radio/fake_radio_profile.dart';

// #770 (A5 of #755): the client's protocol constants must agree with the
// firmware's protocol manifest. Dart tests have no reflection, so both the
// client file and the fake's code table are read as source.

/// `const int name = value;`, across line breaks and trailing comments.
final _constInt = RegExp(
  r'^const int (\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)\s*;',
  multiLine: true,
);

Map<String, int> _constants(String path) => {
  for (final m in _constInt.allMatches(File(path).readAsStringSync()))
    m.group(1)!: int.parse(m.group(2)!),
};

/// `cmdGetAutoAddConfig` and `CMD_GET_AUTOADD_CONFIG` both become
/// `cmdgetautoaddconfig`.
String _key(String name) => name.toLowerCase().replaceAll('_', '');

const _sections = [
  'commands',
  'responses',
  'pushes',
  'errors',
  'offband_commands',
  'offband_responses',
  'offband_caps',
  'offband_caps2',
];

/// Client names that spell a firmware name differently.
const _clientAliases = {'cmdGetCustomVar': 'CMD_GET_CUSTOM_VARS'};

/// Client constants no firmware release defines yet, with why. If the
/// manifest ever defines one under the same name, it is compared like any
/// other.
const _clientOnly = {
  // #429 part A: the client re-polls channels on this push, but no firmware
  // defines PUSH_CODE_CHANNELS_CHANGED (checked offband-v1.5.0-beta7).
  'pushCodeChannelsChanged',
};

class _Report {
  final matched = <String>[];
  final mismatched = <String>[];
  final unknown = <String>[];
}

/// Compares [client] constants with [manifest]; protocol-looking client names
/// the manifest lacks are reported unless allowed.
_Report _compare(Map<String, int> client, FakeRadioManifest manifest) {
  final byKey = <String, MapEntry<String, int>>{};
  for (final s in _sections) {
    for (final e in manifest.section(s).entries) {
      byKey[_key(e.key)] = e;
    }
  }
  final report = _Report();
  client.forEach((name, value) {
    final fw = byKey[_key(_clientAliases[name] ?? name)];
    if (fw == null) {
      final protocolName = RegExp(
        r'^(cmd|respCode|pushCode|offbandCap)',
      ).hasMatch(name);
      if (protocolName && !_clientOnly.contains(name)) report.unknown.add(name);
      return;
    }
    report.matched.add(name);
    if (fw.value != value) {
      report.mismatched.add('$name = $value, firmware ${fw.key} = ${fw.value}');
    }
  });
  return report;
}

void main() {
  final offband = FakeRadioManifest.pinnedOffband();
  final client = _constants('lib/connector/meshcore_protocol.dart');

  group('client protocol constants vs firmware manifest (#770)', () {
    test('every shared code and capability bit has the firmware value', () {
      final r = _compare(client, offband);
      expect(
        r.mismatched,
        isEmpty,
        reason: 'client disagrees with ${offband.ref}',
      );
      // Guard against a check that silently matches nothing.
      expect(r.matched.length, greaterThanOrEqualTo(85));
    });

    test('no protocol constant is unknown to the firmware unless listed', () {
      expect(_compare(client, offband).unknown, isEmpty);
    });

    test('a deliberately wrong constant is caught', () {
      final doctored = Map<String, int>.of(client)
        ..['offbandCapCaplog'] = 0x08
        ..['cmdOffbandPktHash'] = 0xC7;
      expect(_compare(doctored, offband).mismatched, hasLength(2));
    });

    test('the stock manifest agrees on every stock code', () {
      final stock = FakeRadioManifest.pinnedStock();
      final r = _compare(client, stock);
      expect(
        r.mismatched,
        isEmpty,
        reason: 'client disagrees with ${stock.ref}',
      );
    });
  });

  group("fake radio's own codes vs firmware manifest", () {
    test('every fake code has the firmware value', () {
      final fake = _constants('test/support/fake_radio/fake_radio_codes.dart');
      String? fwName(String n) {
        if (n.startsWith('fwCmd')) return 'cmd${n.substring(5)}';
        if (n.startsWith('fwResp')) return 'respCode${n.substring(6)}';
        if (n.startsWith('fwErr')) return 'errCode${n.substring(5)}';
        if (RegExp(r'^fwOffband[A-Z]').hasMatch(n)) {
          return 'cmdOffband${n.substring(9)}';
        }
        return null; // sub-codes, sizes and advert types aren't in manifests
      }

      final renamed = <String, int>{
        for (final e in fake.entries)
          if (fwName(e.key) != null) fwName(e.key)!: e.value,
      };
      final r = _compare(renamed, offband);
      expect(r.mismatched, isEmpty);
      expect(r.matched.length, renamed.length);
    });
  });

  group('reported version and capability gates', () {
    int? caps(List<int> f) => f.length >= 83 ? f[82] : null;
    int? caps2(List<int> f) => f.length >= 85 ? f[84] : null;

    test('the client enables every Offband feature the fake advertises', () {
      final info = FakeRadio().deviceInfoFrame();
      final ver = info[1];
      expect(ver, offband.firmwareVerCode);
      expect(firmwareSupportsOffbandBlock(caps(info), ver), isTrue);
      expect(firmwareSupportsOffbandCaplog(caps(info), ver), isTrue);
      expect(firmwareSupportsPktHash(caps2(info), ver), isTrue);
      expect(firmwareSupportsOffbandGps(caps(info)), isTrue);
    });

    test('the client enables none of them on stock', () {
      final info = FakeRadio(
        profile: FakeRadioProfile.stock(),
      ).deviceInfoFrame();
      final ver = info[1];
      expect(ver, 13);
      expect(caps(info), isNull);
      expect(caps2(info), isNull);
      expect(firmwareSupportsOffbandBlock(caps(info), ver), isFalse);
      expect(firmwareSupportsOffbandCaplog(caps(info), ver), isFalse);
      expect(firmwareSupportsPktHash(caps2(info), ver), isFalse);
      expect(firmwareSupportsOffbandGps(caps(info)), isFalse);
    });
  });
}
