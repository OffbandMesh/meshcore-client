// Epic A verification (#965 / #962): run the production sweep over a copy of a
// REAL database and prove what it did, and what it left alone.
//
// Named `_bench`, not `_test`, so a bare `flutter test` does not collect it:
// it needs a copy of a real database and its numbers are machine-specific. The
// non-flaky gates live in test/storage/stale_history_sweep_test.dart.
//
// Run it:
//   flutter test test/benchmarks/stale_history_sweep_bench.dart \
//     --dart-define=BENCH_DB="$APPDATA/Offband MeshCore/offband_store.sqlite"
//
// The file named by BENCH_DB is COPIED first and never written to. Without it
// the file reports why it ran nothing and passes, because a check that
// silently invents data is worse than one that says it has none.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/stale_history_sweep.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
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
    'the sweep reclaims real blobs and touches nothing else',
    () async {
      if (_benchDb.isEmpty || !File(_benchDb).existsSync()) {
        // ignore: avoid_print
        print(
          'SKIPPED: no BENCH_DB. Pass --dart-define=BENCH_DB=<a real '
          'offband_store.sqlite>. Nothing was measured.',
        );
        return;
      }

      final work = File(
        '${Directory.systemTemp.path}/offband_stale_sweep_bench.sqlite',
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

      // Fingerprint EVERY blob before, so what survives can be compared byte for
      // byte rather than counted.
      final before = <String, String>{};
      for (final key in await blobs.keysWithPrefix('')) {
        final v = await blobs.read(key);
        if (v != null) {
          before[key] = sha256.convert(utf8.encode(v)).toString();
        }
      }
      final rowsBefore = await db
          .customSelect('SELECT COUNT(*) AS c FROM message_records')
          .getSingle()
          .then((r) => r.data['c'] as int);
      final sizeBefore = await blobs.databaseSizeBytes();

      // Age every migrated key past the window. Without this the sweep is
      // correctly a no-op on a database that migrated minutes ago, and the run
      // would prove nothing.
      final marked = await blobs.messageStoreKeys();
      final aged = DateTime.now().subtract(
        staleHistoryWindow + const Duration(days: 1),
      );
      var eligible = 0;
      for (final key in marked) {
        if (!StaleHistorySweep.isHistoryKey(key)) continue;
        if (!await blobs.isOnMessageRows(key)) continue;
        await blobs.setMessageRowsMigratedAtForTest(key, aged);
        eligible++;
      }
      // ignore: avoid_print
      print(
        'blob keys: ${before.length}, migrated history keys aged: $eligible',
      );

      expect(
        eligible,
        greaterThan(0),
        reason:
            'this database has no migrated history key, so the sweep cannot '
            'show anything. Not a pass.',
      );

      final outcome = await StaleHistorySweep(blobs).run();
      final sizeAfter = await blobs.databaseSizeBytes();

      // ignore: avoid_print
      print(
        'cleared ${outcome.cleared.length}, refused ${outcome.refused.length}, '
        '${sizeBefore - sizeAfter} bytes returned '
        '(${((sizeBefore - sizeAfter) / 1048576).toStringAsFixed(2)} MiB)',
      );
      for (final k in outcome.refused) {
        // ignore: avoid_print
        print('  REFUSED (blob kept): $k');
      }

      // What it cleared must be gone, and nothing else may have changed.
      for (final k in outcome.cleared) {
        expect(
          await blobs.read(k),
          isNull,
          reason: '$k should have been cleared',
        );
      }
      final changed = <String>[];
      final missing = <String>[];
      for (final entry in before.entries) {
        if (outcome.cleared.contains(entry.key)) continue;
        final v = await blobs.read(entry.key);
        if (v == null) {
          missing.add(entry.key);
        } else if (sha256.convert(utf8.encode(v)).toString() != entry.value) {
          changed.add(entry.key);
        }
      }
      // ignore: avoid_print
      print(
        'kept keys missing: ${missing.length}, byte-changed: ${changed.length}',
      );

      expect(
        missing,
        isEmpty,
        reason: 'the sweep removed a blob it did not report',
      );
      expect(changed, isEmpty, reason: 'VACUUM must not alter a kept blob');

      final rowsAfter = await db
          .customSelect('SELECT COUNT(*) AS c FROM message_records')
          .getSingle()
          .then((r) => r.data['c'] as int);
      expect(
        rowsAfter,
        rowsBefore,
        reason: 'the history itself must survive losing its stale snapshot',
      );

      final integrity = await db
          .customSelect('PRAGMA integrity_check')
          .getSingle()
          .then((r) => r.data.values.first as String);
      // ignore: avoid_print
      print('integrity_check: $integrity, rows $rowsBefore -> $rowsAfter');
      expect(integrity, 'ok');

      expect(
        sizeAfter,
        lessThan(sizeBefore),
        reason: 'a sweep that cleared blobs must return space',
      );

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
