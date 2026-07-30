import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';

void main() {
  group('DirectRepeater.ranking (SNR-first)', () {
    test('a stronger signal outranks a more-recent but weaker one', () {
      // 5 dB better SNR, but heard 24 min earlier, signal margin must win.
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
      // Weak but live vs strong but stale, the live one must win, so the
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

  group('DirectRepeater.matchesPathStart (#156)', () {
    DirectRepeater repeater(List<int> prefix) => DirectRepeater(
      pubkeyFirstByte: prefix.first,
      pubkeyPrefix: Uint8List.fromList(prefix),
      snr: 12.0,
    );

    test('width 1, matches on the single prefix byte', () {
      expect(repeater([0x84]).matchesPathStart([0x84, 0xab]), isTrue);
      expect(repeater([0x84]).matchesPathStart([0x99]), isFalse);
    });

    test('width 2, both bytes must match, so a 1-byte collision misses', () {
      final r = repeater([0x84, 0xab]);
      expect(r.matchesPathStart([0x84, 0xab, 0xc1]), isTrue);
      // Shares only the first byte, the #156 collision that a 1-byte match
      // would have falsely accepted.
      expect(r.matchesPathStart([0x84, 0x99]), isFalse);
    });

    test('a path shorter than the prefix never matches', () {
      expect(repeater([0x84, 0xab]).matchesPathStart([0x84]), isFalse);
      expect(repeater([0x84]).matchesPathStart(<int>[]), isFalse);
    });
  });

  group(
    'DirectRepeater.recordHop (#150, RX-fed nearest-repeater detection)',
    () {
      DirectRepeater rep(List<int> prefix, double snr) => DirectRepeater(
        pubkeyFirstByte: prefix.last,
        pubkeyPrefix: Uint8List.fromList(prefix),
        snr: snr,
      );

      test('adds a new hop to an empty list', () {
        final list = <DirectRepeater>[];
        final changed = DirectRepeater.recordHop(
          list,
          Uint8List.fromList([0x6a, 0x3d]),
          5.0,
        );
        expect(changed, isTrue);
        expect(list.length, 1);
        expect(list.single.pubkeyPrefix, [0x6a, 0x3d]);
        expect(list.single.snr, 5.0);
      });

      test('an empty prefix is ignored', () {
        final list = <DirectRepeater>[];
        expect(DirectRepeater.recordHop(list, Uint8List(0), 5.0), isFalse);
        expect(list, isEmpty);
      });

      test('refreshes an existing hop; notifies only on a >= 1 dB move', () {
        final list = [
          rep([0x6a, 0x3d], 5.0),
        ];
        // Sub-threshold jitter: value refreshes silently (no notify).
        expect(
          DirectRepeater.recordHop(list, Uint8List.fromList([0x6a, 0x3d]), 5.5),
          isFalse,
        );
        expect(list.single.snr, 5.5);
        expect(list.length, 1);
        // >= 1 dB move: worth a notify.
        expect(
          DirectRepeater.recordHop(list, Uint8List.fromList([0x6a, 0x3d]), 7.0),
          isTrue,
        );
        expect(list.single.snr, 7.0);
      });

      test('at cap, a stronger newcomer evicts the weakest', () {
        final list = [
          rep([0x01, 0x01], 1.0),
          rep([0x02, 0x02], 2.0),
          rep([0x03, 0x03], 3.0),
          rep([0x04, 0x04], 4.0),
          rep([0x05, 0x05], 5.0),
        ];
        expect(
          DirectRepeater.recordHop(list, Uint8List.fromList([0x06, 0x06]), 6.0),
          isTrue,
        );
        expect(list.length, 5);
        expect(list.any((r) => r.snr == 1.0), isFalse); // weakest evicted
        expect(list.any((r) => r.pubkeyPrefix[0] == 0x06), isTrue);
      });

      test('at cap, a newcomer no stronger than the weakest is dropped', () {
        final list = [
          rep([0x01, 0x01], 1.0),
          rep([0x02, 0x02], 2.0),
          rep([0x03, 0x03], 3.0),
          rep([0x04, 0x04], 4.0),
          rep([0x05, 0x05], 5.0),
        ];
        expect(
          DirectRepeater.recordHop(list, Uint8List.fromList([0x06, 0x06]), 0.5),
          isFalse,
        );
        expect(list.length, 5);
        expect(list.any((r) => r.pubkeyPrefix[0] == 0x06), isFalse);
      });
    },
  );
}
