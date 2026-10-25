// #987: the badge's screen and battery settings over 0xC5 0x13 to 0x17, and
// the time zone table, against meshcore-firmware 3e788e2a.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/offband_screen_settings.dart';
import 'package:meshcore_open/models/badge_time_zones.dart';

void main() {
  group('frames', () {
    test('get and each set encode as documented', () {
      expect(buildScreenSettingsGetFrame(), equals([0xC5, 0x13]));
      expect(
        buildTextSizeSetFrame(BadgeTextTarget.messages, BadgeTextSize.small),
        equals([0xC5, 0x14, 1, 2]),
      );
      expect(buildScreenOffSetFrame(300), equals([0xC5, 0x15, 0x2C, 0x01]));
      expect(buildTimeZoneSetFrame(2), equals([0xC5, 0x16, 2]));
      expect(buildBatteryFullSetFrame(pin: true), equals([0xC5, 0x17, 1]));
      expect(buildBatteryFullSetFrame(pin: false), equals([0xC5, 0x17, 0]));
    });
  });

  group('reply', () {
    test('all fourteen bytes, little-endian', () {
      final r = parseScreenSettingsReply(
        Uint8List.fromList([
          0xC5, 0x15, //
          0, 1, // nav large, messages medium
          0x3C, 0x00, // stored 60 s
          0x3C, 0x00, // waits 60 s
          2, // Eastern
          0x36, 0x10, // 4150 mV stored
          0x36, 0x10, // 4150 mV in use
          0, // learned
        ]),
      )!;
      final s = r.screen!;
      expect(s.navText, BadgeTextSize.large);
      expect(s.messageText, BadgeTextSize.medium);
      expect(s.screenOffStored, 60);
      expect(s.screenOffIsDefault, isFalse);
      expect(s.timeZone, 2);
      expect(s.batteryFullStored, 4150);
      expect(s.batteryPinned, isFalse);
    });

    test('a short reply is never shown as the radio\'s state', () {
      expect(
        parseScreenSettingsReply(Uint8List.fromList([0xC5, 0x13, 0, 1])),
        isNull,
      );
    });

    test('screen off labels', () {
      expect(screenOffSteps.map(screenOffLabel), [
        '15 s',
        '30 s',
        '1 m',
        '2 m',
        '5 m',
      ]);
    });
  });

  group('time zones', () {
    test('the table matches firmware: 41 entries, indices pinned', () {
      expect(badgeTimeZones.length, 41);
      expect(badgeTimeZones[0].name, 'not set');
      expect(badgeTimeZones[2].name, 'Eastern');
      expect(badgeTimeZones[12].name, 'UTC-12');
      expect(badgeTimeZones.last.name, 'UTC+9:30');
    });

    test('US daylight time, both edges', () {
      // 2026: DST runs Mar 8 07:00 UTC to Nov 1 06:00 UTC for Eastern.
      expect(timeZoneOffsetMinutes(2, DateTime.utc(2026, 3, 8, 6, 59)), -300);
      expect(timeZoneOffsetMinutes(2, DateTime.utc(2026, 3, 8, 7)), -240);
      expect(timeZoneOffsetMinutes(2, DateTime.utc(2026, 11, 1, 5, 59)), -240);
      expect(timeZoneOffsetMinutes(2, DateTime.utc(2026, 11, 1, 6)), -300);
      // Arizona keeps standard time all year.
      expect(timeZoneOffsetMinutes(5, DateTime.utc(2026, 7, 1)), -420);
    });

    test('EU summer time, both edges', () {
      // 2026: last Sundays are Mar 29 and Oct 25, at 01:00 UTC.
      expect(timeZoneOffsetMinutes(10, DateTime.utc(2026, 3, 29, 0, 59)), 60);
      expect(timeZoneOffsetMinutes(10, DateTime.utc(2026, 3, 29, 1)), 120);
      expect(timeZoneOffsetMinutes(10, DateTime.utc(2026, 10, 25, 1)), 60);
    });

    test('not set and unknown indices have no offset', () {
      expect(timeZoneOffsetMinutes(0, DateTime.utc(2026)), isNull);
      expect(timeZoneOffsetMinutes(99, DateTime.utc(2026)), isNull);
      expect(timeZoneName(99), 'Zone 99');
    });

    test('offset labels', () {
      expect(formatUtcOffset(-240), 'UTC-4');
      expect(formatUtcOffset(330), 'UTC+5:30');
      expect(formatUtcOffset(0), 'UTC+0');
    });

    // A phone whose offset follows the US Eastern rule.
    Duration eastern(DateTime local) =>
        Duration(minutes: timeZoneOffsetMinutes(2, local.toUtc())!);

    test('a phone on Eastern is offered Eastern, not UTC-4', () {
      expect(
        suggestTimeZone(now: DateTime(2026, 10, 25, 12), offsetAt: eastern),
        2,
      );
    });

    test('a phone with no daylight rule gets the fixed offset', () {
      expect(
        suggestTimeZone(
          now: DateTime(2026, 10, 25, 12),
          offsetAt: (_) => const Duration(minutes: 330),
        ),
        39,
      );
    });

    test('a phone on UTC gets UTC, not the UK', () {
      expect(
        suggestTimeZone(
          now: DateTime(2026, 10, 25, 12),
          offsetAt: (_) => Duration.zero,
        ),
        1,
      );
    });

    test('an offset with no zone suggests nothing', () {
      expect(
        suggestTimeZone(
          now: DateTime(2026, 10, 25, 12),
          offsetAt: (_) => const Duration(minutes: 345),
        ),
        isNull,
      );
    });
  });
}
