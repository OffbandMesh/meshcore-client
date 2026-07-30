import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/path_selection_dialog.dart';

void main() {
  group('PathSelectionDialog.parsePathPrefixes (#155)', () {
    test('width 1, single-byte hops', () {
      final invalid = <String>[];
      expect(PathSelectionDialog.parsePathPrefixes('A1,F2,3C', 1, invalid), [
        0xA1,
        0xF2,
        0x3C,
      ]);
      expect(invalid, isEmpty);
    });

    test('width 2, two-byte hops, each entry 4 hex chars', () {
      final invalid = <String>[];
      expect(PathSelectionDialog.parsePathPrefixes('84AB,C1D2', 2, invalid), [
        0x84,
        0xAB,
        0xC1,
        0xD2,
      ]);
      expect(invalid, isEmpty);
    });

    test('wrong-length entries are rejected, never silently truncated', () {
      final invalid = <String>[];
      // too short (1 byte) and too long (3 bytes) on a 2-byte mesh
      final bytes = PathSelectionDialog.parsePathPrefixes(
        '84,AABBCC',
        2,
        invalid,
      );
      expect(bytes, isEmpty);
      expect(invalid, ['84', 'AABBCC']);
    });

    test('non-hex entry is rejected', () {
      final invalid = <String>[];
      PathSelectionDialog.parsePathPrefixes('ZZ', 1, invalid);
      expect(invalid, ['ZZ']);
    });

    test('width < 1 is clamped to 1', () {
      final invalid = <String>[];
      expect(PathSelectionDialog.parsePathPrefixes('A1', 0, invalid), [0xA1]);
      expect(invalid, isEmpty);
    });

    test('empty input → empty path', () {
      final invalid = <String>[];
      expect(PathSelectionDialog.parsePathPrefixes('', 2, invalid), isEmpty);
      expect(invalid, isEmpty);
    });
  });
}
