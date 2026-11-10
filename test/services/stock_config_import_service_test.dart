// #575 (epic #568): import merge semantics.
//
// Stock's own import screen states the rules: contacts are upserted, existing
// channels never change. The channel planner is where that rule lives, so it is
// tested directly. Applying to a device is the T1 hardware gate's job.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/stock_config.dart';
import 'package:meshcore_open/services/stock_config_import_service.dart';

Uint8List psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

Channel live(int index, String name, int fill) =>
    Channel(index: index, name: name, psk: psk(fill));

StockChannel incoming(String name, int fill) =>
    StockChannel(name: name, secret: psk(fill));

void main() {
  group('channel import planning', () {
    test(
      'a channel the device does not have goes into the first free slot',
      () {
        final plan = planChannelImport(
          existing: [live(0, 'Public', 0x11)],
          incoming: [incoming('Weather', 0x22)],
          maxChannels: 40,
          isSyncing: false,
        );

        expect(plan.assignments, hasLength(1));
        expect(plan.assignments.single.slot, 1);
        expect(plan.skipped, isEmpty);
      },
    );

    test('a matching psk is left alone, matching stock', () {
      final plan = planChannelImport(
        existing: [live(0, 'Public', 0x11)],
        incoming: [incoming('Renamed', 0x11)],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped.single.reason, StockConfigImportIssue.alreadyPresent);
    });

    test('a rotated psk under an existing name does NOT overwrite', () {
      // This is stock's rule and it is surprising: importing a file with a new
      // key for a channel the user already has is a no-op. We match it, but the
      // skip is reported rather than silent.
      final plan = planChannelImport(
        existing: [live(0, 'Public', 0x11)],
        incoming: [incoming('Public', 0x99)],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped.single.name, 'Public');
      expect(plan.skipped.single.reason, StockConfigImportIssue.alreadyPresent);
    });

    test('empty slots are reused, and gaps are filled lowest first', () {
      // Slot 1 is empty while 0 and 2 are taken, so the newcomer lands in 1.
      final plan = planChannelImport(
        existing: [
          live(0, 'Public', 0x11),
          Channel(index: 1, name: '', psk: Uint8List(16)),
          live(2, 'Weather', 0x22),
        ],
        incoming: [incoming('Emergency', 0x33)],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments.single.slot, 1);
    });

    test('several new channels take consecutive free slots in file order', () {
      final plan = planChannelImport(
        existing: [live(0, 'Public', 0x11)],
        incoming: [
          incoming('First', 0x22),
          incoming('Second', 0x33),
          incoming('Third', 0x44),
        ],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments.map((a) => a.slot), [1, 2, 3]);
      expect(plan.assignments.map((a) => a.channel.name), [
        'First',
        'Second',
        'Third',
      ]);
    });

    test('a full device reports every leftover instead of dropping it', () {
      final plan = planChannelImport(
        existing: [live(0, 'A', 0x11), live(1, 'B', 0x22)],
        incoming: [incoming('C', 0x33), incoming('D', 0x44)],
        maxChannels: 2,
        isSyncing: false,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped.map((s) => s.name), ['C', 'D']);
      expect(
        plan.skipped.map((s) => s.reason),
        everyElement(StockConfigImportIssue.noFreeSlot),
      );
    });

    test('a duplicate inside the file itself is only written once', () {
      final plan = planChannelImport(
        existing: const [],
        incoming: [incoming('Dupe', 0x55), incoming('Dupe', 0x55)],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments, hasLength(1));
      expect(plan.skipped.single.reason, StockConfigImportIssue.alreadyPresent);
    });

    test('nothing incoming means nothing planned and nothing skipped', () {
      final plan = planChannelImport(
        existing: [live(0, 'Public', 0x11)],
        incoming: const [],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped, isEmpty);
    });

    // #1117: firmware #1896 refuses any channel but Public in slot 0, even
    // while it is empty, and refuses Public anywhere else.
    test('no channel but Public is planned into slot 0', () {
      final plan = planChannelImport(
        existing: const [],
        incoming: [incoming('Weather', 0x22), incoming('Emergency', 0x33)],
        maxChannels: 40,
        isSyncing: false,
      );

      expect(plan.assignments.map((a) => a.slot), [1, 2]);
    });

    test('Public in the file goes to slot 0 when it is free', () {
      final plan = planChannelImport(
        existing: const [],
        incoming: [
          incoming('Weather', 0x22),
          StockChannel(
            name: 'Public',
            secret: Channel.parsePskHex(Channel.publicChannelPsk),
          ),
        ],
        maxChannels: 40,
        isSyncing: false,
      );

      final bySlot = {for (final a in plan.assignments) a.channel.name: a.slot};
      expect(bySlot['Public'], 0);
      expect(bySlot['Weather'], 1);
    });

    test('a radio full but for slot 0 has no room for other channels', () {
      final plan = planChannelImport(
        existing: [for (var i = 1; i < 4; i++) live(i, 'c$i', 0x40 + i)],
        incoming: [incoming('Weather', 0x22)],
        maxChannels: 4,
        isSyncing: false,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped.single.reason, StockConfigImportIssue.noFreeSlot);
    });

    // #1021: the connector empties its channel list for the length of a sync,
    // so mid-sync `existing` looks empty. Planning then would write every
    // incoming channel over slots that are really occupied, starting at 0.
    test('mid-sync nothing is written, even into slots that look free', () {
      final plan = planChannelImport(
        existing: const [],
        incoming: [incoming('Weather', 0x22), incoming('Emergency', 0x33)],
        maxChannels: 40,
        isSyncing: true,
      );

      expect(plan.assignments, isEmpty);
      expect(plan.skipped.map((s) => s.name), ['Weather', 'Emergency']);
      expect(
        plan.skipped.map((s) => s.reason),
        everyElement(StockConfigImportIssue.channelsSyncing),
      );
    });

    test('mid-sync every channel is reported as syncing, not as present', () {
      // A partial list cannot prove a channel is already there either, so
      // "already present" would be a guess. Syncing is the true reason.
      final plan = planChannelImport(
        existing: [live(0, 'Public', 0x11)],
        incoming: [incoming('Public', 0x11)],
        maxChannels: 40,
        isSyncing: true,
      );

      expect(plan.assignments, isEmpty);
      expect(
        plan.skipped.single.reason,
        StockConfigImportIssue.channelsSyncing,
      );
    });
  });

  group('import result', () {
    test('skipped channels alone make a result incomplete', () {
      const result = StockConfigImportResult(
        applied: {},
        failed: {},
        skippedChannels: [
          SkippedChannel('Public', StockConfigImportIssue.alreadyPresent),
        ],
        contactsWritten: 0,
        channelsAdded: 0,
      );

      expect(result.isComplete, isFalse);
    });

    test('a clean run is complete', () {
      const result = StockConfigImportResult(
        applied: {},
        failed: {},
        skippedChannels: [],
        contactsWritten: 3,
        channelsAdded: 1,
      );

      expect(result.isComplete, isTrue);
    });
  });
}
