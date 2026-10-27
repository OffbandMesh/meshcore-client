// Epic B verification (#920 / #917): migrate a REAL database into rows and
// prove nothing was lost, then show that a save no longer cares how much
// history is already stored.
//
// Named `_bench`, not `_test`, so a bare `flutter test` does not collect it:
// it needs a copy of a real database and its numbers are machine-specific.
// The non-flaky gates live in test/storage/message_rows_*_test.dart.
//
// Run it:
//   flutter test test/benchmarks/real_db_row_migration_bench.dart \
//     --dart-define=BENCH_DB="$APPDATA/Offband MeshCore/offband_store.sqlite"
//
// The file named by BENCH_DB is COPIED first and never written to. Without it
// the whole file reports why it ran nothing and passes, because a benchmark
// that silently invents data is worse than one that says it has none.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/message_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _benchDb = String.fromEnvironment('BENCH_DB');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  tearDown(BlobStore.clearTestOverride);

  test(
    'count parity: every message in a real database survives',
    () async {
      if (_benchDb.isEmpty || !File(_benchDb).existsSync()) {
        // ignore: avoid_print
        print(
          'SKIPPED: no BENCH_DB. Pass --dart-define=BENCH_DB=<copy of a real '
          'offband_store.sqlite>. Nothing was measured.',
        );
        return;
      }

      final work = File(
        '${Directory.systemTemp.path}/offband_row_migration_bench.sqlite',
      );
      if (work.existsSync()) work.deleteSync();
      File(_benchDb).copySync(work.path);
      // ignore: avoid_print
      print(
        'working on a copy: ${work.path} '
        '(${(work.lengthSync() / 1048576).toStringAsFixed(2)} MiB)',
      );

      final db = OffbandDatabase(NativeDatabase(work));
      final blobs = BlobStore(db);
      BlobStore.overrideForTest(blobs);

      // Snapshot every message-history blob BEFORE anything touches it: the key,
      // its exact bytes and how many records it holds, counted here rather than
      // by the converter under test.
      final before = <String, ({int length, int records, int hash})>{};
      final rows = await db
          .customSelect('SELECT key, value FROM stored_blobs')
          .get();
      for (final r in rows) {
        final key = r.data['key'] as String;
        if (!key.startsWith('channel_messages_') &&
            !key.startsWith('messages_')) {
          continue;
        }
        final value = r.data['value'] as String;
        if (value.isEmpty) continue;
        int records;
        try {
          records = (jsonDecode(value) as List<dynamic>).length;
        } catch (e) {
          // ignore: avoid_print
          print('  ! $key does not decode at all, skipping: $e');
          continue;
        }
        before[key] = (
          length: value.length,
          records: records,
          hash: value.hashCode,
        );
      }

      expect(
        before,
        isNotEmpty,
        reason:
            'the named database holds no message history, so this '
            'measured nothing',
      );

      var totalRecords = 0;
      var totalRows = 0;
      final refused = <String>[];
      final sw = Stopwatch()..start();

      for (final entry in before.entries) {
        final key = entry.key;
        final converter = key.startsWith('channel_messages_')
            ? channelHistoryToRows
            : dmHistoryToRows;
        final ok = await blobs.ensureMessageRowsMigrated(key, converter);
        final stored = await blobs.messageRowCount(key);
        totalRecords += entry.value.records;
        totalRows += stored;
        if (!ok) refused.add(key);
      }
      final elapsed = sw.elapsedMilliseconds;

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print(
        'keys migrated     : ${before.length - refused.length}'
        ' of ${before.length}',
      );
      // ignore: avoid_print
      print('records in blobs  : $totalRecords');
      // ignore: avoid_print
      print('rows stored       : $totalRows');
      // ignore: avoid_print
      print('elapsed           : ${elapsed}ms');
      if (refused.isNotEmpty) {
        // ignore: avoid_print
        print('REFUSED (still on their blob):');
        for (final k in refused) {
          // ignore: avoid_print
          print('  $k (${before[k]!.records} records)');
        }
      }

      // The blobs must come out untouched. This is the promise that makes the
      // migration recoverable.
      final after = await db
          .customSelect('SELECT key, value FROM stored_blobs')
          .get();
      for (final r in after) {
        final key = r.data['key'] as String;
        final snapshot = before[key];
        if (snapshot == null) continue;
        final value = r.data['value'] as String;
        expect(
          value.length,
          snapshot.length,
          reason: '$key changed length, so the migration wrote to a blob',
        );
        expect(
          value.hashCode,
          snapshot.hash,
          reason: '$key changed content, so the migration wrote to a blob',
        );
      }

      // A record can legitimately vanish only as a duplicate identity, never
      // otherwise, so rows may be fewer but must never exceed, and a shortfall
      // has to be explainable.
      expect(
        totalRows,
        lessThanOrEqualTo(totalRecords),
        reason: 'more rows than records means the migration invented messages',
      );
      if (totalRows != totalRecords) {
        // ignore: avoid_print
        print(
          'NOTE: ${totalRecords - totalRows} records collapsed into existing '
          'identities (duplicates in the source blobs) or belong to refused '
          'keys. Per-key detail is in the log above.',
        );
      }
      expect(
        refused,
        isEmpty,
        reason:
            'every key in a real database should migrate; a refusal is a '
            'finding, not a pass',
      );

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'the one-time migration does not freeze the UI isolate',
    () async {
      // The question an existing install actually asks: when this ships and
      // the biggest channel migrates on first open, does the app lock up?
      // Measured the way #919 measured it, with a 1 ms heartbeat on the main
      // isolate; the worst gap between beats is the freeze.
      if (_benchDb.isEmpty || !File(_benchDb).existsSync()) {
        // ignore: avoid_print
        print('SKIPPED: no BENCH_DB. Nothing was measured.');
        return;
      }

      final work = File(
        '${Directory.systemTemp.path}/offband_row_migration_ui.sqlite',
      );
      if (work.existsSync()) work.deleteSync();
      File(_benchDb).copySync(work.path);

      // `createInBackground`, not a plain NativeDatabase, because that is what
      // ships: `drift_flutter`'s `driftDatabase()` hosts the connection in a
      // background isolate. Measuring on a same-isolate connection charges SQL
      // execution to the UI isolate and overstates the freeze, which is what
      // the first version of this test did: it read 166 ms where the
      // production-shaped connection reads 64 ms.
      final db = OffbandDatabase(NativeDatabase.createInBackground(work));
      final blobs = BlobStore(db);
      BlobStore.overrideForTest(blobs);

      final biggest = await db
          .customSelect(
            'SELECT key, length(value) AS n FROM stored_blobs '
            "WHERE key LIKE 'channel_messages_%' "
            'ORDER BY length(value) DESC LIMIT 1',
          )
          .getSingle();
      final key = biggest.data['key'] as String;
      final size = biggest.data['n'] as int;

      var last = DateTime.now();
      var worst = 0;
      var beats = 0;
      final beat = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = DateTime.now();
        final gap = now.difference(last).inMilliseconds;
        if (gap > worst) worst = gap;
        last = now;
        beats++;
      });
      final sw = Stopwatch()..start();
      last = DateTime.now();
      final ok = await blobs.ensureMessageRowsMigrated(
        key,
        channelHistoryToRows,
      );
      final wall = sw.elapsedMilliseconds;
      // The overdue beat has to land before the timer goes away, or a real
      // block reads as 0 ms. Learned the hard way in #919.
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      beat.cancel();

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print(
        'migrating the largest channel: '
        '${(size / 1048576).toStringAsFixed(2)} MiB, '
        '${await blobs.messageRowCount(key)} messages',
      );
      // ignore: avoid_print
      print('  UI blocked ${worst}ms   wall ${wall}ms   (heartbeats $beats)');

      expect(ok, isTrue);
      expect(
        beats,
        greaterThan(10),
        reason: 'too few heartbeats to trust the gap figure',
      );

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'per-message save cost is flat across history length',
    () async {
      final db = OffbandDatabase(NativeDatabase.memory());
      final blobs = BlobStore(db);
      BlobStore.overrideForTest(blobs);

      String payloadFor(int i) => jsonEncode({
        'senderName': 's',
        'text': 'message number $i with a realistic amount of text in it',
        'timestamp': 1700000000000 + i,
        'isOutgoing': false,
        'channelIndex': 0,
        'messageId': 'id$i',
        'status': 0,
      });

      // ignore: avoid_print
      print('');
      // ignore: avoid_print
      print('history size   one more save');
      for (final size in [500, 5000, 50000]) {
        final key = 'k$size';
        await blobs.upsertMessageRows(key, [
          for (var i = 0; i < size; i++)
            MessageRowInput(
              mergeKey: 'id:id$i',
              timestampMs: 1700000000000 + i,
              payload: payloadFor(i),
            ),
        ]);

        final samples = <int>[];
        for (var n = 0; n < 20; n++) {
          final sw = Stopwatch()..start();
          await blobs.upsertMessageRows(key, [
            MessageRowInput(
              mergeKey: 'id:new$n',
              timestampMs: 1800000000000 + n,
              payload: payloadFor(900000 + n),
            ),
          ]);
          samples.add(sw.elapsedMicroseconds);
        }
        samples.sort();
        final median = samples[samples.length ~/ 2];
        // ignore: avoid_print
        print(
          '${size.toString().padLeft(11)}   '
          '${(median / 1000).toStringAsFixed(3)} ms',
        );
      }

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
