import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/time_anomaly.dart';

void main() {
  final arrival = DateTime(2026, 7, 18, 22, 47, 3);

  group('isRxTimeAnomaly (#285)', () {
    test('equal times are not anomalous', () {
      expect(isRxTimeAnomaly(arrival, arrival), isFalse);
    });

    test('within 24h either direction is not anomalous', () {
      expect(
        isRxTimeAnomaly(arrival, arrival.subtract(const Duration(hours: 23))),
        isFalse,
      );
      expect(
        isRxTimeAnomaly(arrival, arrival.add(const Duration(hours: 23))),
        isFalse,
      );
    });

    test('beyond 24h either direction is anomalous', () {
      expect(
        isRxTimeAnomaly(arrival, arrival.subtract(const Duration(hours: 25))),
        isTrue,
      );
      expect(
        isRxTimeAnomaly(arrival, arrival.add(const Duration(hours: 25))),
        isTrue,
      );
    });

    test('the #280 case (claimed 64 days in the past) is anomalous', () {
      final claimed = arrival.subtract(const Duration(days: 64, hours: 5));
      expect(isRxTimeAnomaly(arrival, claimed), isTrue);
    });

    test('custom threshold is honored', () {
      expect(
        isRxTimeAnomaly(
          arrival,
          arrival.subtract(const Duration(minutes: 10)),
          threshold: const Duration(minutes: 5),
        ),
        isTrue,
      );
    });
  });

  group('formatRxTimeDelta (#285)', () {
    test('zero delta', () {
      expect(formatRxTimeDelta(arrival, arrival), '0s');
    });

    test('claimed in the past is negative, days+hours', () {
      final claimed = arrival.subtract(const Duration(days: 64, hours: 5));
      expect(formatRxTimeDelta(arrival, claimed), '-64d5h');
    });

    test('claimed ahead is positive, minutes only', () {
      final claimed = arrival.add(const Duration(minutes: 3));
      expect(formatRxTimeDelta(arrival, claimed), '+3m');
    });

    test('sub-minute deltas fall back to seconds', () {
      final claimed = arrival.subtract(const Duration(seconds: 45));
      expect(formatRxTimeDelta(arrival, claimed), '-45s');
    });

    test('exact whole days omit smaller units', () {
      final claimed = arrival.subtract(const Duration(days: 2));
      expect(formatRxTimeDelta(arrival, claimed), '-2d');
    });

    test('caps at two units (no minute tail after days+hours)', () {
      final claimed = arrival.subtract(
        const Duration(days: 1, hours: 2, minutes: 30),
      );
      expect(formatRxTimeDelta(arrival, claimed), '-1d2h');
    });
  });
}
