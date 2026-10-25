/// The badge's time zone table, a copy of firmware `src/helpers/TimeZones.h`
/// on meshcore-firmware `firmware-base` at `f3d30a88` (#987).
///
/// The radio stores a zone as an index into this list, so the order is the
/// contract. Firmware keeps it append-only ("Append only; never reorder"), so
/// a copy can only fall behind; an index past the end is shown by number.
library;

enum DstRule { none, us, eu }

class BadgeTimeZone {
  const BadgeTimeZone(this.name, this.standardMinutes, this.rule);
  final String name;
  final int standardMinutes;
  final DstRule rule;
}

const int timeZoneNotSet = 0;

const List<BadgeTimeZone> badgeTimeZones = [
  BadgeTimeZone('not set', 0, DstRule.none),
  BadgeTimeZone('UTC', 0, DstRule.none),
  BadgeTimeZone('Eastern', -300, DstRule.us),
  BadgeTimeZone('Central', -360, DstRule.us),
  BadgeTimeZone('Mountain', -420, DstRule.us),
  BadgeTimeZone('Arizona', -420, DstRule.none),
  BadgeTimeZone('Pacific', -480, DstRule.us),
  BadgeTimeZone('Alaska', -540, DstRule.us),
  BadgeTimeZone('Hawaii', -600, DstRule.none),
  BadgeTimeZone('UK', 0, DstRule.eu),
  BadgeTimeZone('Central EU', 60, DstRule.eu),
  BadgeTimeZone('Eastern EU', 120, DstRule.eu),
  BadgeTimeZone('UTC-12', -720, DstRule.none),
  BadgeTimeZone('UTC-11', -660, DstRule.none),
  BadgeTimeZone('UTC-10', -600, DstRule.none),
  BadgeTimeZone('UTC-9', -540, DstRule.none),
  BadgeTimeZone('UTC-8', -480, DstRule.none),
  BadgeTimeZone('UTC-7', -420, DstRule.none),
  BadgeTimeZone('UTC-6', -360, DstRule.none),
  BadgeTimeZone('UTC-5', -300, DstRule.none),
  BadgeTimeZone('UTC-4', -240, DstRule.none),
  BadgeTimeZone('UTC-3', -180, DstRule.none),
  BadgeTimeZone('UTC-2', -120, DstRule.none),
  BadgeTimeZone('UTC-1', -60, DstRule.none),
  BadgeTimeZone('UTC+1', 60, DstRule.none),
  BadgeTimeZone('UTC+2', 120, DstRule.none),
  BadgeTimeZone('UTC+3', 180, DstRule.none),
  BadgeTimeZone('UTC+4', 240, DstRule.none),
  BadgeTimeZone('UTC+5', 300, DstRule.none),
  BadgeTimeZone('UTC+6', 360, DstRule.none),
  BadgeTimeZone('UTC+7', 420, DstRule.none),
  BadgeTimeZone('UTC+8', 480, DstRule.none),
  BadgeTimeZone('UTC+9', 540, DstRule.none),
  BadgeTimeZone('UTC+10', 600, DstRule.none),
  BadgeTimeZone('UTC+11', 660, DstRule.none),
  BadgeTimeZone('UTC+12', 720, DstRule.none),
  BadgeTimeZone('UTC+13', 780, DstRule.none),
  BadgeTimeZone('UTC+14', 840, DstRule.none),
  BadgeTimeZone('UTC-3:30', -210, DstRule.none),
  BadgeTimeZone('UTC+5:30', 330, DstRule.none),
  BadgeTimeZone('UTC+9:30', 570, DstRule.none),
];

/// The first fixed-offset zone (`kFirstFixed`).
const int _firstFixedZone = 12;

bool _isSet(int index) => index > 0 && index < badgeTimeZones.length;

/// The zone's name, or the raw index for one this client does not know.
String timeZoneName(int index) => index >= 0 && index < badgeTimeZones.length
    ? badgeTimeZones[index].name
    : 'Zone $index';

int _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  final toSunday = (DateTime.sunday - first.weekday) % 7;
  return 1 + toSunday + 7 * (n - 1);
}

int _lastSunday(int year, int month) {
  final last = DateTime.utc(year, month + 1, 0);
  return last.day - (last.weekday % 7);
}

/// Port of firmware `inDaylightSaving()`: US from 02:00 local on the second
/// Sunday of March to 02:00 local daylight time on the first Sunday of
/// November; EU from 01:00 UTC on the last Sunday of March to 01:00 UTC on
/// the last Sunday of October.
bool _inDaylightSaving(BadgeTimeZone z, DateTime utc) {
  final y = utc.year;
  switch (z.rule) {
    case DstRule.us:
      final start = DateTime.utc(
        y,
        3,
        _nthSunday(y, 3, 2),
        2,
      ).subtract(Duration(minutes: z.standardMinutes));
      final end = DateTime.utc(
        y,
        11,
        _nthSunday(y, 11, 1),
        2,
      ).subtract(Duration(minutes: z.standardMinutes + 60));
      return !utc.isBefore(start) && utc.isBefore(end);
    case DstRule.eu:
      final start = DateTime.utc(y, 3, _lastSunday(y, 3), 1);
      final end = DateTime.utc(y, 10, _lastSunday(y, 10), 1);
      return !utc.isBefore(start) && utc.isBefore(end);
    case DstRule.none:
      return false;
  }
}

/// Minutes to add to UTC at [utc] in zone [index], daylight saving included.
/// Null for "not set" and for an index this client does not know.
int? timeZoneOffsetMinutes(int index, DateTime utc) {
  if (!_isSet(index)) return null;
  final z = badgeTimeZones[index];
  return z.standardMinutes + (_inDaylightSaving(z, utc.toUtc()) ? 60 : 0);
}

/// "UTC-4", "UTC+5:30", "UTC+0".
String formatUtcOffset(int minutes) {
  final sign = minutes < 0 ? '-' : '+';
  final a = minutes.abs();
  final mins = a % 60;
  return 'UTC$sign${a ~/ 60}${mins == 0 ? '' : ':${mins.toString().padLeft(2, '0')}'}';
}

/// The zone that matches the phone, as the badge suggests one from GPS.
///
/// A named zone matches when its offset equals the phone's now, in January and
/// in July, so its daylight rule agrees as well as its current offset. Failing
/// that, the fixed zone for the phone's current offset. Null when nothing fits.
///
/// [offsetAt] is the phone's UTC offset at a local instant; injectable so the
/// match can be tested without depending on the machine's own zone.
int? suggestTimeZone({
  required DateTime now,
  required Duration Function(DateTime local) offsetAt,
}) {
  final year = now.year;
  final probes = [now, DateTime(year, 1, 15, 12), DateTime(year, 7, 15, 12)];
  // From 2: UTC (1) is the fallback below, so a UK phone in winter is not
  // offered plain UTC.
  for (var i = 2; i < _firstFixedZone; i++) {
    final matches = probes.every(
      (t) => timeZoneOffsetMinutes(i, t.toUtc()) == offsetAt(t).inMinutes,
    );
    if (matches) return i;
  }
  final current = offsetAt(now).inMinutes;
  if (current == 0) return 1;
  for (var i = _firstFixedZone; i < badgeTimeZones.length; i++) {
    if (badgeTimeZones[i].standardMinutes == current) return i;
  }
  return null;
}
