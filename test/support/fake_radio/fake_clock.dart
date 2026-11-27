/// The fake radio's only notion of time. Nothing it does waits on the wall
/// clock: scheduled work runs when a test calls [advance], so the same seed and
/// the same steps always give the same result.
class FakeClock {
  FakeClock({int epochSeconds = 1790000000}) : _baseEpoch = epochSeconds;

  int _baseEpoch;
  Duration _elapsed = Duration.zero;
  final List<_Scheduled> _queue = [];
  int _sequence = 0;

  Duration get elapsed => _elapsed;

  /// Seconds since the Unix epoch, as the radio's RTC reports it.
  int get epochSeconds => _baseEpoch + _elapsed.inSeconds;

  /// Sets the RTC (CMD_SET_DEVICE_TIME) without moving scheduled work.
  set epochSeconds(int value) => _baseEpoch = value - _elapsed.inSeconds;

  /// Runs [action] once [after] has elapsed on this clock.
  void schedule(Duration after, void Function() action) {
    _queue.add(_Scheduled(_elapsed + after, _sequence++, action));
  }

  /// Moves time forward, running everything that falls due, in order. Work
  /// scheduled while advancing runs too, if it falls due before the target.
  void advance(Duration by) {
    final target = _elapsed + by;
    while (true) {
      _queue.sort((a, b) {
        final byTime = a.due.compareTo(b.due);
        return byTime != 0 ? byTime : a.sequence.compareTo(b.sequence);
      });
      if (_queue.isEmpty || _queue.first.due > target) break;
      final next = _queue.removeAt(0);
      _elapsed = next.due;
      next.action();
    }
    _elapsed = target;
  }

  int get pending => _queue.length;
}

class _Scheduled {
  _Scheduled(this.due, this.sequence, this.action);

  final Duration due;
  final int sequence;
  final void Function() action;
}
