import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  group('parseDeviceInfoStrings', () {
    Uint8List frameWith(List<String> strings, {bool pad = true}) {
      final frame = <int>[0x0d, 0x0e, 0x02, 0x03, 0, 0, 0, 0]; // 8-byte header
      for (final s in strings) {
        frame.addAll(s.codeUnits);
        frame.add(0); // NUL terminator
      }
      if (pad) {
        while (frame.length < 80) {
          frame.add(0);
        }
        frame.addAll([1, 1, 0]); // client_repeat, path-hash mode, caps
      }
      return Uint8List.fromList(frame);
    }

    test('extracts build date, model, and firmware version in order', () {
      final out = parseDeviceInfoStrings(
        frameWith(['24-Jun-2026', 'RAK 3401', '1.7.1']),
      );
      expect(out, ['24-Jun-2026', 'RAK 3401', '1.7.1']);
    });

    test('returns empty for a header-only frame', () {
      expect(
        parseDeviceInfoStrings(Uint8List.fromList(List<int>.filled(8, 0))),
        isEmpty,
      );
    });

    test('ignores printable bytes in the binary config block (byte 80+)', () {
      final frame = <int>[0x0d, 0x0e, 0, 0, 0, 0, 0, 0];
      frame.addAll('1.7.1'.codeUnits);
      frame.add(0);
      while (frame.length < 80) {
        frame.add(0);
      }
      frame.addAll('ABCD'.codeUnits); // printable but past the scan window
      expect(parseDeviceInfoStrings(Uint8List.fromList(frame)), ['1.7.1']);
    });
  });

  group('deviceInfoFields', () {
    test('three strings map to build date, model, and version', () {
      final f = deviceInfoFields(['24-Jun-2026', 'RAK 3401', '1.7.1']);
      expect(f.version, '1.7.1');
      expect(f.model, 'RAK 3401');
      expect(f.buildDate, '24-Jun-2026');
    });

    test('two strings keep version + model, drop build date', () {
      final f = deviceInfoFields(['RAK 3401', '1.7.1']);
      expect(f.version, '1.7.1');
      expect(f.model, 'RAK 3401');
      expect(f.buildDate, isNull);
    });

    test('one string is the version', () {
      final f = deviceInfoFields(['1.7.1']);
      expect(f.version, '1.7.1');
      expect(f.model, isNull);
      expect(f.buildDate, isNull);
    });

    test('empty maps to all null', () {
      final f = deviceInfoFields([]);
      expect(f.version, isNull);
      expect(f.model, isNull);
      expect(f.buildDate, isNull);
    });
  });
}
