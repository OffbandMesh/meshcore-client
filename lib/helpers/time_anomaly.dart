/// Ingest time-anomaly detection (#285, child of #280).
///
/// A received message carries the SENDER's claimed timestamp in its payload;
/// nothing guarantees that clock is sane. These helpers compare the claimed
/// time against the local arrival time so the ingest log can prove, after the
/// fact, whether an odd date came in on the wire.
library;

/// Claimed-vs-arrival gap beyond which a received message is logged as a
/// time anomaly. Generous enough for mesh store-and-forward delays and
/// timezone-free radio clocks; months-off RTCs blow well past it.
const Duration rxTimeAnomalyThreshold = Duration(hours: 24);

/// True when the sender-claimed [claimed] time is further than [threshold]
/// from the local [arrival] time in either direction.
bool isRxTimeAnomaly(
  DateTime arrival,
  DateTime claimed, {
  Duration threshold = rxTimeAnomalyThreshold,
}) {
  return claimed.difference(arrival).abs() > threshold;
}

/// Compact human delta of claimed relative to arrival, e.g. `-64d5h` (claimed
/// 64 days in the past) or `+3m` (claimed 3 minutes ahead). `0s` when equal.
String formatRxTimeDelta(DateTime arrival, DateTime claimed) {
  final delta = claimed.difference(arrival);
  if (delta == Duration.zero) return '0s';
  final sign = delta.isNegative ? '-' : '+';
  var d = delta.abs();
  final parts = <String>[];
  if (d.inDays > 0) {
    parts.add('${d.inDays}d');
    d -= Duration(days: d.inDays);
  }
  if (d.inHours > 0) {
    parts.add('${d.inHours}h');
    d -= Duration(hours: d.inHours);
  }
  if (parts.length < 2 && d.inMinutes > 0) {
    parts.add('${d.inMinutes}m');
    d -= Duration(minutes: d.inMinutes);
  }
  if (parts.isEmpty) parts.add('${d.inSeconds}s');
  return '$sign${parts.take(2).join()}';
}
