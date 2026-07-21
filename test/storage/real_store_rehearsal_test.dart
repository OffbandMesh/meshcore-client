@Tags(['rehearsal'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rehearses the #335 migration against a COPY of a real 7 MB store.
///
/// Required by the plan before the migration may touch live data. Reads a
/// snapshot from disk; it never opens the user's actual store. Skipped when
/// the snapshot is absent, so CI does not depend on one machine's data.
void main() {
  final path = Platform.environment['OFFBAND_REAL_STORE'];

  test(
    'migrates a real 7 MB store with zero loss',
    () async {
      if (path == null || !File(path).existsSync()) {
        markTestSkipped(
          'set OFFBAND_REAL_STORE to a shared_preferences.json copy',
        );
        return;
      }

      final raw =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      // Strip the `flutter.` prefix the plugin adds on disk.
      final seed = <String, Object>{
        for (final e in raw.entries)
          if (e.value is String || e.value is int || e.value is bool)
            e.key.replaceFirst('flutter.', ''): e.value as Object,
      };

      final expected = <String, int>{
        for (final e in seed.entries)
          if (e.value is String && BlobStore.isBulkKey(e.key))
            e.key: (e.value as String).length,
      };

      SharedPreferences.setMockInitialValues(seed);
      PrefsManager.reset();
      await PrefsManager.initialize();

      final db = OffbandDatabase(NativeDatabase.memory());
      final store = BlobStore(db);
      final report = await store.migrateFromPrefs();

      // ignore: avoid_print
      print(
        'REHEARSAL: ${report.migrated} migrated, ${report.failed} failed, '
        '${(report.bytes / 1024 / 1024).toStringAsFixed(2)} MB, '
        '${expected.length} bulk keys expected',
      );

      expect(report.failed, 0, reason: 'no key may fail on real data');
      expect(report.migrated, expected.length);

      // Every byte accounted for, per key.
      for (final e in expected.entries) {
        final got = await store.read(e.key);
        expect(got, isNotNull, reason: '${e.key} missing after migration');
        expect(got!.length, e.value, reason: '${e.key} changed length');
        expect(
          PrefsManager.instance.get(e.key),
          isNull,
          reason: '${e.key} should be gone from prefs',
        );
      }

      // Settings must survive untouched.
      final settings = seed.keys.where((k) => !BlobStore.isBulkKey(k));
      for (final k in settings) {
        expect(
          PrefsManager.instance.get(k),
          isNotNull,
          reason: 'setting $k was wrongly removed',
        );
      }

      await db.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
