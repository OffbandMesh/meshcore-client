import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';

void main() {
  group('DirectRepeater.ranking (SNR-first)', () {
    test('a stronger signal outranks a more-recent but weaker one', () {
      // 5 dB better SNR, but heard 24 min earlier — signal margin must win.
      final strongOld = DirectRepeater(
        pubkeyFirstByte: 1,
        pubkeyPrefix: Uint8List.fromList([1]),
        snr: 10.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 25)),
      );
      final weakRecent = DirectRepeater(
        pubkeyFirstByte: 2,
        pubkeyPrefix: Uint8List.fromList([2]),
        snr: 5.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(strongOld.ranking, greaterThan(weakRecent.ranking));
    });

    test('recency breaks ties between equal-SNR repeaters', () {
      final older = DirectRepeater(
        pubkeyFirstByte: 1,
        pubkeyPrefix: Uint8List.fromList([1]),
        snr: 10.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 20)),
      );
      final newer = DirectRepeater(
        pubkeyFirstByte: 2,
        pubkeyPrefix: Uint8List.fromList([2]),
        snr: 10.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(newer.ranking, greaterThan(older.ranking));
    });

    test('a stale repeater ranks -1', () {
      final stale = DirectRepeater(
        pubkeyFirstByte: 1,
        pubkeyPrefix: Uint8List.fromList([1]),
        snr: 30.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 31)),
      );
      expect(stale.ranking, -1);
    });

    test('a live repeater always outranks a stale one', () {
      // Weak but live vs strong but stale — the live one must win, so the
      // stale sentinel (-1) has to sit below every live ranking.
      final weakLive = DirectRepeater(
        pubkeyFirstByte: 1,
        pubkeyPrefix: Uint8List.fromList([1]),
        snr: -30.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final strongStale = DirectRepeater(
        pubkeyFirstByte: 2,
        pubkeyPrefix: Uint8List.fromList([2]),
        snr: 30.0,
        lastUpdated: DateTime.now().subtract(const Duration(minutes: 31)),
      );
      expect(weakLive.ranking, greaterThan(strongStale.ranking));
    });
  });

  group('DirectRepeater.prefixHex (#151)', () {
    test('renders the full configured-width prefix as hex', () {
      final r = DirectRepeater(
        pubkeyFirstByte: 0xf4,
        pubkeyPrefix: Uint8List.fromList([0xf4, 0xab]),
        snr: 12.0,
      );
      expect(r.prefixHex, 'f4ab');
    });

    test('single-byte prefix renders two hex chars', () {
      final r = DirectRepeater(
        pubkeyFirstByte: 0x84,
        pubkeyPrefix: Uint8List.fromList([0x84]),
        snr: 12.0,
      );
      expect(r.prefixHex, '84');
    });
  });
}
