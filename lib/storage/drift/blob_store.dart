import '../../utils/app_logger.dart';
import '../prefs_manager.dart';
import 'offband_database.dart';

/// Bulk-data store backed by drift, replacing SharedPreferences for anything
/// large (#335).
///
/// Why this exists: SharedPreferences is a settings store. On Windows every
/// mutation re-encodes and rewrites the WHOLE file synchronously, and on web it
/// is backed by `localStorage`, which is capped at 5 MiB per origin and is also
/// synchronous. This install holds ~5.2 MB of bulk data, so the web build
/// cannot function at all today and Windows stalls for tens of seconds (#306).
///
/// Each key becomes one row, so a write touches one row rather than the entire
/// store.
class BlobStore {
  BlobStore(this._db);

  final OffbandDatabase _db;

  static OffbandDatabase? _sharedDb;

  /// Process-wide instance. The database must be opened once; opening it twice
  /// is an error on the web backends.
  static BlobStore get instance => BlobStore(_sharedDb ??= OffbandDatabase());

  /// Key families that hold bulk data. Everything else stays in
  /// SharedPreferences, which is what it is for.
  static const List<String> migratedPrefixes = [
    'channel_messages_',
    'messages_',
    'contacts',
    'discovered_contacts',
  ];

  static bool isBulkKey(String key) => migratedPrefixes.any(key.startsWith);

  Future<String?> read(String key) async {
    final row = await (_db.select(
      _db.storedBlobs,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> write(String key, String value) async {
    await _db
        .into(_db.storedBlobs)
        .insertOnConflictUpdate(
          StoredBlobsCompanion.insert(key: key, value: value),
        );
  }

  Future<void> delete(String key) async {
    await (_db.delete(_db.storedBlobs)..where((t) => t.key.equals(key))).go();
  }

  /// Moves bulk keys out of SharedPreferences into drift.
  ///
  /// Ordering is deliberate and non-negotiable: **write, verify by reading
  /// back, and only then remove the source.** #333 was caused by a storage path
  /// that chose a key silently and made 566 real messages read as empty; a
  /// migration that deleted before verifying could do that permanently rather
  /// than cosmetically.
  ///
  /// Idempotent: keys already migrated are skipped, so re-running is a no-op
  /// rather than a duplicate or an overwrite of newer data.
  ///
  /// Every outcome is logged (SAFELANE 6). A failure never silently drops a
  /// key: the source is left intact and the error surfaces.
  Future<MigrationReport> migrateFromPrefs() async {
    final prefs = PrefsManager.instance;
    final report = MigrationReport();

    final bulkKeys = prefs.getKeys().where(isBulkKey).toList();
    if (bulkKeys.isEmpty) {
      appLogger.info(
        'Blob migration: nothing to migrate (already done or fresh install)',
        tag: 'Storage',
      );
      return report;
    }

    appLogger.info(
      'Blob migration: ${bulkKeys.length} key(s) to move out of prefs',
      tag: 'Storage',
    );

    for (final key in bulkKeys) {
      try {
        // Type-check rather than calling getString directly: getString THROWS
        // on a non-string value, which would be counted as a migration failure
        // and cry wolf. A non-string under a bulk prefix is simply not bulk
        // data.
        final raw = prefs.get(key);
        if (raw is! String || raw.isEmpty) {
          report.skipped++;
          continue;
        }
        final source = raw;

        if (await read(key) != null) {
          // Already migrated on a previous run. Leave the prefs copy for the
          // sweep below rather than assuming; the read-back proved the data is
          // present in drift.
          report.alreadyPresent++;
          await prefs.remove(key);
          continue;
        }

        await write(key, source);

        // Verify BEFORE removing the source. Length is compared rather than
        // full equality to keep a multi-MB comparison cheap while still
        // catching truncation, which is the realistic corruption here.
        final readBack = await read(key);
        if (readBack == null || readBack.length != source.length) {
          report.failed++;
          appLogger.error(
            'Blob migration FAILED for $key: wrote ${source.length} chars, '
            'read back ${readBack?.length ?? "null"}. Source left intact.',
            tag: 'Storage',
          );
          continue;
        }

        await prefs.remove(key);
        report.migrated++;
        report.bytes += source.length;
      } catch (e) {
        report.failed++;
        appLogger.error(
          'Blob migration FAILED for $key: $e. Source left intact.',
          tag: 'Storage',
        );
      }
    }

    final level = report.failed > 0 ? 'WITH FAILURES' : 'ok';
    appLogger.info(
      'Blob migration complete ($level): ${report.migrated} moved, '
      '${report.alreadyPresent} already present, ${report.skipped} skipped, '
      '${report.failed} failed, '
      '${(report.bytes / 1024 / 1024).toStringAsFixed(2)} MB',
      tag: 'Storage',
    );
    if (report.failed > 0) {
      appLogger.error(
        'Blob migration left ${report.failed} key(s) in SharedPreferences. '
        'No data was lost, but those keys still carry the old cost.',
        tag: 'Storage',
      );
    }
    return report;
  }
}

/// Mutable tally of a migration run; surfaced in the log and used by tests.
class MigrationReport {
  int migrated = 0;
  int alreadyPresent = 0;
  int skipped = 0;
  int failed = 0;
  int bytes = 0;

  bool get hadFailures => failed > 0;
}
