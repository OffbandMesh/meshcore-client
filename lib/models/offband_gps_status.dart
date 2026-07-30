/// Parsed payload of a `RESP_CODE_OFFBAND_GPS` (0xC1) reply, the on-demand GPS
/// state from an Offband-fork companion radio. (#135)
///
/// Wire format is one ASCII string of space-separated `key=value` tokens, e.g.
/// `enabled=1 detected=1 active=1 fix=1 lat=39421530 lon=-84449000 alt_cm=23390 sats=12 time=1782531085`.
/// `lat`/`lon` are 1e-6 degrees (same units as the SELF_INFO frame).
class OffbandGpsStatus {
  final bool enabled;
  final bool detected;
  final bool active;
  final bool fix;
  final double? latitude;
  final double? longitude;
  final int? altitudeCm;
  final int? satellites;
  final DateTime? timestampUtc;

  const OffbandGpsStatus({
    required this.enabled,
    required this.detected,
    required this.active,
    required this.fix,
    this.latitude,
    this.longitude,
    this.altitudeCm,
    this.satellites,
    this.timestampUtc,
  });

  /// True when the radio reports a live satellite fix with usable coordinates,
  /// i.e. position is GPS-driven, not a stored/manual location. (#135)
  bool get hasLiveFix => fix && latitude != null && longitude != null;

  /// Parses the ASCII `key=value` reply string. Unknown/missing keys are
  /// tolerated (null); `lat`/`lon` are scaled from 1e-6 degrees.
  static OffbandGpsStatus parse(String raw) {
    final fields = <String, String>{};
    for (final token in raw.trim().split(RegExp(r'\s+'))) {
      final eq = token.indexOf('=');
      if (eq > 0) fields[token.substring(0, eq)] = token.substring(eq + 1);
    }
    int? asInt(String key) {
      final v = fields[key];
      return v == null ? null : int.tryParse(v);
    }

    final lat = asInt('lat');
    final lon = asInt('lon');
    final time = asInt('time');
    return OffbandGpsStatus(
      enabled: fields['enabled'] == '1',
      detected: fields['detected'] == '1',
      active: fields['active'] == '1',
      fix: fields['fix'] == '1',
      latitude: lat == null ? null : lat / 1e6,
      longitude: lon == null ? null : lon / 1e6,
      altitudeCm: asInt('alt_cm'),
      satellites: asInt('sats'),
      timestampUtc: (time == null || time <= 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true),
    );
  }
}
