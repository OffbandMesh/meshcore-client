import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/storage_health_service.dart';

/// #385: the service must default to healthy and flip loudly (notifying) the
/// moment storage is proven unusable.
void main() {
  test('defaults to available with no error', () {
    final s = StorageHealthService();
    expect(s.available, isTrue);
    expect(s.error, isNull);
  });

  test('markUnavailable flips state, records the error, and notifies', () {
    final s = StorageHealthService();
    var notifications = 0;
    s.addListener(() => notifications++);

    s.markUnavailable(Exception('sqlite3.dll not found'));

    expect(s.available, isFalse);
    expect(s.error, contains('sqlite3.dll not found'));
    expect(notifications, 1);
  });

  test('one-way latch: a later mark is a no-op and keeps the first error', () {
    final s = StorageHealthService();
    var notifications = 0;
    s.addListener(() => notifications++);

    s.markUnavailable('first');
    s.markUnavailable('second');

    expect(notifications, 1, reason: 'stays unavailable, does not re-notify');
    expect(s.available, isFalse);
    expect(s.error, contains('first'), reason: 'first error is retained');
  });
}
