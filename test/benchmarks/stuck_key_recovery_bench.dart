// #952 verification: the keys the old gate trapped recover against a REAL
// database, with no healing migration.
//
// Named `_bench`, not `_test`, so a bare `flutter test` does not collect it:
// it needs a copy of a real database. The non-flaky gates live in
// test/storage/migration_readback_gate_test.dart.
//
// Run it:
//   flutter test test/benchmarks/stuck_key_recovery_bench.dart \
//     --dart-define=BENCH_DB="$APPDATA/Offband MeshCore/offband_store.sqlite"
//
// The file named by BENCH_DB is COPIED first and never written to. Without it
// the file reports why it ran nothing and passes, because a check that
// silently invents data is worse than one that says it has none.
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
    'every key with rows but no marker migrates on next access',
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
        '${Directory.systemTemp.path}/offband_stuck_key_recovery.sqlite',
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

      // The stuck shape, identified without using the code under test: a key
      // that has rows and is NOT in the migrated marker.
      final withRows = await blobs.messageStoreKeys();
      final marked = <String>{};
      final rawMarker = await blobs.read(BlobStore.migratedMarkerKey);
      if (rawMarker != null && rawMarker.isNotEmpty) {
        marked.addAll((jsonDecode(rawMarker) as List<dynamic>).cast<String>());
      }
      final stuck = withRows.difference(marked).toList()..sort();

      // ignore: avoid_print
      print(
        'keys with rows: ${withRows.length}, marked migrated: ${marked.length}, '
        'rows but unmarked: ${stuck.length}',
      );

      if (stuck.isEmpty) {
        // ignore: avoid_print
        print(
          'This database has no key in the stuck shape, so it cannot show the '
          'recovery. Not a pass for #952.',
        );
        markTestSkipped('no stuck keys in the named database');
        await db.close();
        return;
      }

      final recovered = <String>[];
      final refused = <String>[];

      for (final key in stuck) {
        final blob = await blobs.read(key);
        final records = blob == null || blob.isEmpty
            ? 0
            : (jsonDecode(blob) as List<dynamic>).length;
        final rowsBefore = await blobs.messageRowCount(key);

        final ok = await blobs.ensureMessageRowsMigrated(
          key,
          key.startsWith('channel_messages_')
              ? channelHistoryToRows
              : dmHistoryToRows,
        );

        final rowsAfter = await blobs.messageRowCount(key);
        // ignore: avoid_print
        print(
          '  ${ok ? 'MIGRATED' : 'REFUSED '} blob=$records rows $rowsBefore'
          ' -> $rowsAfter  $key',
        );
        (ok ? recovered : refused).add(key);

        if (ok) {
          // Every blob record must be readable as a row, and the extra rows
          // that caused the old refusal must still be there.
          expect(
            rowsAfter,
            greaterThanOrEqualTo(records),
            reason: '$key lost records while migrating',
          );
          expect(await blobs.isOnMessageRows(key), isTrue);
        }
      }

      // ignore: avoid_print
      print('recovered: ${recovered.length}, still refused: ${refused.length}');

      expect(
        refused,
        isEmpty,
        reason:
            'these keys are still stuck, so #952 is not fixed for this '
            'database: $refused',
      );

      // The blobs are retained, as #920 promises, so nothing here is destructive.
      for (final key in recovered) {
        expect(
          await blobs.read(key),
          isNotNull,
          reason: '$key lost its retained blob',
        );
      }

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
