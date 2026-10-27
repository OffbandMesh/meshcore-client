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

/// Non-empty `messageId`s in a history blob, read straight from the JSON.
///
/// Deliberately not via the converter: this is used to check the converter's
/// output, so sharing its code would make the check circular.
List<String> _messageIdsIn(String? blob) {
  if (blob == null || blob.isEmpty) return const [];
  return (jsonDecode(blob) as List<dynamic>)
      .map((e) => (e as Map<String, dynamic>)['messageId'] as String?)
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toList();
}

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
          expect(
            rowsAfter,
            greaterThanOrEqualTo(records),
            reason: '$key lost records while migrating',
          );
          expect(await blobs.isOnMessageRows(key), isTrue);

          // Counts alone would pass against a converter that produced the
          // right NUMBER of rows with the wrong contents (Gemini review).
          // Identity and payloads are checked too, derived from the raw blob
          // rather than from the converter under test, so this is not
          // circular.
          //
          // Only records carrying a messageId are identity-checked: the `x:`
          // fallback merge key would mean reimplementing the converter here,
          // which would make the check circular again. The count assertion
          // above still covers those.
          final ids = _messageIdsIn(blob);
          final stored = await blobs.messageMergeKeys(key);
          final absent = ids.where((id) => !stored.contains('id:$id')).toList();
          expect(
            absent,
            isEmpty,
            reason:
                '$key: ${absent.length} of ${ids.length} identified messages '
                'in the blob have no row carrying their identity',
          );

          final payloads = await blobs.messagePayloads(key);
          expect(
            payloads.where((p) => p.trim().length <= 2),
            isEmpty,
            reason: '$key stored empty payloads',
          );
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
