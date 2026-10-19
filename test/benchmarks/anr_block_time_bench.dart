// Epic A verification benchmark (#919 / #917): how long does saving one
// channel message block the isolate that draws the UI?
//
// The filename ends in `_bench`, not `_test`, so a bare `flutter test` does
// not collect it: the numbers depend on the machine and on a local copy of a
// real database, which makes this a measurement tool rather than a gate. It
// lives under test/ anyway so the analyzer treats it as test code. The
// non-flaky gate is test/storage/blob_merge_runs_off_main_isolate_test.dart.
//
// Run it:
//   1. copy a real database somewhere local, e.g.
//      cp "$APPDATA/Offband MeshCore/offband_store.sqlite" /tmp/live_copy.sqlite
//   2. flutter test test/benchmarks/anr_block_time_bench.dart \
//        --dart-define=BENCH_DB=/tmp/live_copy.sqlite
//
// Without BENCH_DB it synthesises a payload of a comparable size, which is
// fine for a regression check and useless as evidence about real data.
//
// What it measures: a 1 ms heartbeat timer runs on the main isolate while the
// save happens. The largest gap between heartbeats IS the UI freeze, which is
// what Android's input-dispatch watchdog kills an app for. Wall-clock duration
// of the save is reported too, because the point of Epic A is that those two
// numbers come apart: the work still takes just as long, it just stops
// happening where the UI lives.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _benchDb = String.fromEnvironment('BENCH_DB');

/// Records the worst gap between 1 ms heartbeats while [action] runs. A gap is
/// time the main isolate was not free to do anything, UI included.
///
/// The yield before `cancel` is load-bearing. A periodic timer cannot fire
/// while the isolate is blocked, so the gap only becomes visible on the first
/// tick *after* the block; cancelling the moment the action returns throws that
/// tick away and reports a block of 0 ms. Verified: a bare 200 ms busy-wait
/// with no trailing yield measured `fires=0, worst=0ms`, and the same block
/// with a yield measured 200 ms.
///
/// [fires] is reported for the same reason. A run with few fires has not
/// proven anything, whatever its gap says.
Future<({int maxGapMs, int wallMs, int fires})> _withHeartbeat(
  Future<void> Function() action,
) async {
  var last = DateTime.now();
  var worst = 0;
  var fires = 0;
  final beat = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final now = DateTime.now();
    final gap = now.difference(last).inMilliseconds;
    if (gap > worst) worst = gap;
    last = now;
    fires++;
  });
  final sw = Stopwatch()..start();
  last = DateTime.now();
  await action();
  final wall = sw.elapsedMilliseconds;
  // Let the overdue tick land before the timer goes away.
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  beat.cancel();
  return (maxGapMs: worst, wallMs: wall, fires: fires);
}

void main() {
  test(
    'one save: UI-isolate block time, old path vs new path',
    () async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();

      String payload;
      if (_benchDb.isNotEmpty && File(_benchDb).existsSync()) {
        final source = OffbandDatabase(NativeDatabase(File(_benchDb)));
        final rows = await source
            .customSelect(
              'select value from stored_blobs '
              'order by length(value) desc limit 1',
            )
            .get();
        payload = rows.single.data['value'] as String;
        await source.close();
        // ignore: avoid_print
        print('payload: real, from $_benchDb');
      } else {
        // ignore: avoid_print
        print(
          'payload: SYNTHETIC (pass --dart-define=BENCH_DB=... for real '
          'data; these numbers are not evidence about production)',
        );
        final one = jsonEncode({
          'senderName': 'synthetic',
          'text': 'x' * 120,
          'timestamp': 1700000000000,
          'isOutgoing': false,
          'channelIndex': 0,
          'messageId': 'id',
          'status': 0,
        });
        payload = '[${List.filled(9230, one).join(',')}]';
      }
      // ignore: avoid_print
      print(
        'payload size: ${payload.length} chars '
        '(${(payload.length / 1048576).toStringAsFixed(2)} MiB)',
      );

      final db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      final blobs = BlobStore.instance;

      // One more message arriving, encoded the way the store encodes it.
      final incoming = jsonEncode([
        {
          'senderName': 'bench',
          'text': 'the message that just arrived',
          'timestamp': 1800000000000,
          'isOutgoing': false,
          'channelIndex': 0,
          'messageId': 'bench-1',
          'status': 0,
        },
      ]);

      // OLD path: exactly what the store did before #919, calling the very
      // same merge function inline instead of through compute. Not a strawman:
      // the only difference is where it runs.
      await blobs.write('old', payload);
      final old = await _withHeartbeat(() async {
        final stored = await blobs.readWithPrefsFallback('old');
        final merged = mergeChannelHistoryJson((stored, incoming));
        await blobs.write('old', merged);
      });

      // NEW path.
      await blobs.write('new', payload);
      final fresh = await _withHeartbeat(
        () => blobs.mergeOffThread('new', incoming, mergeChannelHistoryJson),
      );

      // A burst of five, which is the case that crosses the watchdog.
      await blobs.write('burst_old', payload);
      final burstOld = await _withHeartbeat(() async {
        for (var i = 0; i < 5; i++) {
          final stored = await blobs.readWithPrefsFallback('burst_old');
          await blobs.write(
            'burst_old',
            mergeChannelHistoryJson((stored, incoming)),
          );
        }
      });

      await blobs.write('burst_new', payload);
      final burstNew = await _withHeartbeat(() async {
        for (var i = 0; i < 5; i++) {
          await blobs.mergeOffThread(
            'burst_new',
            incoming,
            mergeChannelHistoryJson,
          );
        }
      });

      void report(String label, ({int maxGapMs, int wallMs, int fires}) r) {
        // ignore: avoid_print
        print(
          '${label.padRight(26)} UI blocked ${r.maxGapMs}ms   '
          'wall ${r.wallMs}ms   (heartbeats ${r.fires})',
        );
      }

      // ignore: avoid_print
      print('');
      report('1 save, inline (pre-#919)', old);
      report('1 save, off-thread (#919)', fresh);
      report('5 saves, inline', burstOld);
      report('5 saves, off-thread', burstNew);

      await db.close();
      BlobStore.clearTestOverride();

      // Sanity, not a threshold: the off-thread path must not block longer
      // than the inline one. Real thresholds are the owner's device check.
      expect(fresh.maxGapMs, lessThanOrEqualTo(old.maxGapMs));
      expect(burstNew.maxGapMs, lessThanOrEqualTo(burstOld.maxGapMs));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
