import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/offband_gps_status.dart';

void main() {
  group('OffbandGpsStatus.parse', () {
    test('parses a full reply with a live fix', () {
      final s = OffbandGpsStatus.parse(
        'enabled=1 detected=1 active=1 fix=1 lat=39421530 lon=-84449000 '
        'alt_cm=23390 sats=12 time=1782531085',
      );
      expect(s.enabled, isTrue);
      expect(s.detected, isTrue);
      expect(s.active, isTrue);
      expect(s.fix, isTrue);
      expect(s.latitude, closeTo(39.42153, 1e-9));
      expect(s.longitude, closeTo(-84.449, 1e-9));
      expect(s.altitudeCm, 23390);
      expect(s.satellites, 12);
      expect(
        s.timestampUtc,
        DateTime.fromMillisecondsSinceEpoch(1782531085 * 1000, isUtc: true),
      );
      expect(s.hasLiveFix, isTrue);
    });

    test('no fix → flags false, hasLiveFix false even with stale coords', () {
      final s = OffbandGpsStatus.parse(
        'enabled=1 detected=1 active=0 fix=0 lat=39421530 lon=-84449000 '
        'sats=0 time=0',
      );
      expect(s.fix, isFalse);
      expect(s.active, isFalse);
      expect(s.hasLiveFix, isFalse);
      expect(s.timestampUtc, isNull); // time=0 → null
    });

    test('missing optional keys are tolerated', () {
      final s = OffbandGpsStatus.parse('enabled=0 detected=0 active=0 fix=0');
      expect(s.enabled, isFalse);
      expect(s.latitude, isNull);
      expect(s.longitude, isNull);
      expect(s.altitudeCm, isNull);
      expect(s.satellites, isNull);
      expect(s.timestampUtc, isNull);
      expect(s.hasLiveFix, isFalse);
    });

    test('extra whitespace and unknown keys are ignored', () {
      final s = OffbandGpsStatus.parse(
        '  enabled=1   fix=1  foo=bar  lat=1000000 lon=2000000  ',
      );
      expect(s.enabled, isTrue);
      expect(s.fix, isTrue);
      expect(s.latitude, closeTo(1.0, 1e-9));
      expect(s.longitude, closeTo(2.0, 1e-9));
      expect(s.hasLiveFix, isTrue);
    });
  });
}
