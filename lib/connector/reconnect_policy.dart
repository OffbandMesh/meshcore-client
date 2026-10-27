/// The budget for automatic reconnects after a link drops (#997).
///
/// An automatic retry stops after [maxAttempts] attempts, or once the next one
/// would start more than [window] after the first, whichever comes first.
/// Only [reset] clears the count: an automatic attempt must never reset it,
/// which is what let the client retry an unreachable radio for hours (#995).
class ReconnectPolicy {
  ReconnectPolicy({
    this.maxAttempts = 5,
    this.window = const Duration(minutes: 3),
  });

  final int maxAttempts;
  final Duration window;

  int _attempts = 0;
  DateTime? _startedAt;

  /// Attempts scheduled since the last [reset].
  int get attempts => _attempts;

  /// The delay before the next attempt, or null when the budget is spent.
  Duration? nextDelay(DateTime now) {
    if (_attempts >= maxAttempts) return null;
    final startedAt = _startedAt ??= now;
    final delay = Duration(seconds: 1 << _attempts);
    if (now.add(delay).difference(startedAt) >= window) return null;
    _attempts += 1;
    return delay;
  }

  void reset() {
    _attempts = 0;
    _startedAt = null;
  }
}
