// #574 (epic #568): the export file name has to match stock's convention and
// survive real device names, which contain emoji and trailing spaces.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/stock_config_file.dart';

void main() {
  final at = DateTime(2026, 8, 12, 22, 16, 25);

  test('matches stock: name, then meshcore_config, then a stamp', () {
    expect(
      stockConfigFileName('Strycher-RAK-CAR', at),
      'Strycher-RAK-CAR_meshcore_config_2026-08-12-221625.json',
    );
  });

  test('single-digit months, days and times are zero padded', () {
    expect(
      stockConfigFileName('Node', DateTime(2026, 1, 2, 3, 4, 5)),
      'Node_meshcore_config_2026-01-02-030405.json',
    );
  });

  test('emoji in a device name are kept, as stock keeps them', () {
    expect(
      stockConfigFileName('Strycher T1000\u{1F6F0}️', at),
      startsWith('Strycher T1000\u{1F6F0}️_meshcore_config_'),
    );
  });

  test('a trailing space is dropped, since Windows rejects it', () {
    // Observed in a real export: the device name ended in a space.
    expect(
      stockConfigFileName('Strycher-Wio-L1 ', at),
      'Strycher-Wio-L1_meshcore_config_2026-08-12-221625.json',
    );
  });

  test('path separators and reserved characters are stripped', () {
    expect(
      stockConfigFileName(r'a/b\c:d*e?f"g<h>i|j', at),
      'abcdefghij_meshcore_config_2026-08-12-221625.json',
    );
  });

  test('a device with no name still produces a usable file name', () {
    expect(
      stockConfigFileName(null, at),
      'meshcore_config_2026-08-12-221625.json',
    );
    expect(
      stockConfigFileName('   ', at),
      'meshcore_config_2026-08-12-221625.json',
    );
  });
}
