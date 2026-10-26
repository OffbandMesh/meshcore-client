// Bounded auto-reconnect (#997, design on #995).
//
// On 2026-10-25 the client retried an unreachable T1000-E every ~1 s for 7.7
// hours: connect() reset the attempt counter at the start of every automatic
// attempt, so the backoff never grew and nothing ever gave up. The policy owns
// the counter now, and only an explicit reset clears it.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/reconnect_policy.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 26, 12);

  test('delays grow 1, 2, 4, 8, 16 s across the five allowed attempts', () {
    final policy = ReconnectPolicy();
    final delays = [
      for (var i = 0; i < 5; i++)
        policy.nextDelay(t0.add(Duration(seconds: i)))!.inSeconds,
    ];
    expect(delays, [1, 2, 4, 8, 16]);
  });

  test('gives up after five attempts', () {
    final policy = ReconnectPolicy();
    for (var i = 0; i < 5; i++) {
      expect(policy.nextDelay(t0), isNotNull);
    }
    expect(policy.nextDelay(t0), isNull);
    expect(policy.attempts, 5);
  });

  test('gives up after three minutes even with attempts left', () {
    final policy = ReconnectPolicy();
    expect(policy.nextDelay(t0), isNotNull);
    expect(
      policy.nextDelay(t0.add(const Duration(minutes: 3))),
      isNull,
      reason: 'the window runs from the first scheduled attempt',
    );
  });

  test('a delay never carries the retry past the three minute window', () {
    final policy = ReconnectPolicy();
    policy.nextDelay(t0);
    final delay = policy.nextDelay(
      t0.add(const Duration(minutes: 2, seconds: 59)),
    );
    expect(delay, isNull, reason: 'the attempt would start after 3 min');
  });

  test('reset starts a fresh budget', () {
    final policy = ReconnectPolicy();
    for (var i = 0; i < 5; i++) {
      policy.nextDelay(t0);
    }
    policy.reset();
    final later = t0.add(const Duration(minutes: 10));
    expect(policy.attempts, 0);
    expect(policy.nextDelay(later)!.inSeconds, 1);
  });
}
