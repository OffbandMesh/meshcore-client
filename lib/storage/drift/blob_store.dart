import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

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
  static BlobStore? _override;

  /// Process-wide instance. The database must be opened once; opening it twice
  /// is an error on the web backends.
  static BlobStore get instance =>
      _override ?? BlobStore(_sharedDb ??= OffbandDatabase());

  /// Test seam: point the singleton at an in-memory database.
  @visibleForTesting
  static void overrideForTest(BlobStore store) => _override = store;

  @visibleForTesting
  static void clearTestOverride() => _override = null;

  /// Key families that hold bulk data. Everything else stays in
  /// SharedPreferences, which is what it is for.
  static const List<String> migratedPrefixes = [
    'channel_messages_',
    'messages_',
    'contacts',
    'discovered_contacts',
  ];

  static bool isBulkKey(String key) => migratedPrefixes.any(key.startsWith);

  /// Per-key operation chain. Merge-on-save and the legacy-key migration are
  /// read-modify-write sequences with an await gap; two of them racing on the
  /// same key would let the second clobber the first and silently lose
  /// messages (Gemini review, 2026-07-20). Every RMW on a key runs through
  /// [synchronized], which serialises operations per key while leaving
  /// different keys concurrent.
  final Map<String, Future<void>> _keyChains = {};

  /// Serialises [action] against other synchronized actions on the same [key].
  Future<T> synchronized<T>(String key, Future<T> Function() action) {
    final prior = _keyChains[key] ?? Future<void>.value();
    final result = prior.then((_) => action());
    // Next op waits for this one; swallow errors so one failure does not wedge
    // the chain for the key.
    _keyChains[key] = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Reads a bulk key, falling back to SharedPreferences if drift does not
  /// have it.
  ///
  /// Belt and braces for the switchover: if migration ever missed a key, the
  /// data must still be reachable rather than silently reading as empty, which
  /// is exactly how #333 presented. The fallback is LOUD, because a fallback
  /// that fires in normal operation means the migration is incomplete and
  /// somebody needs to know.
  Future<String?> readWithPrefsFallback(String key) async {
    final fromDrift = await read(key);
    if (fromDrift != null) return fromDrift;

    final raw = PrefsManager.instance.get(key);
    if (raw is! String || raw.isEmpty) return null;

    appLogger.warn(
      'Blob read for $key fell back to SharedPreferences: it is NOT in drift. '
      'Migration is incomplete for this key; serving the prefs copy.',
      tag: 'Storage',
    );
    return raw;
  }

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

  /// Keys beginning with [prefix], across BOTH backends.
  ///
  /// Callers that clear a family of keys must see prefs-resident keys too, or
  /// a pre-migration copy survives the clear and reappears through the read
  /// fallback.
  Future<List<String>> keysWithPrefix(String prefix) async {
    // Filtered in Dart rather than SQL: the table holds tens of rows, so the
    // cost is irrelevant and it avoids depending on a version-specific LIKE
    // API for a pinned dependency.
    final rows = await _db.select(_db.storedBlobs).get();

    return {
      ...rows.map((r) => r.key).where((k) => k.startsWith(prefix)),
      ...PrefsManager.instance.getKeys().where((k) => k.startsWith(prefix)),
    }.toList();
  }

  /// Removes a key from BOTH backends, so a clear cannot be undone by a
  /// leftover prefs copy surfacing through the fallback.
  Future<void> deleteEverywhere(String key) async {
    await delete(key);
    await PrefsManager.instance.remove(key);
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

        final existing = await read(key);
        if (existing != null) {
          // Drift already holds this key. Do NOT discard the prefs copy: a
          // build that writes to SharedPreferences (a non-drift build, or any
          // in-between test build) accumulates NEW messages there, and throwing
          // them away silently gaps the history across test cycles (#355). Union
          // the prefs copy into drift by message identity, keeping drift's live
          // entries, then verify before removing the source.
          final merged = _mergeBulk(existing, source);
          if (merged == null) {
            // Not a JSON list (e.g. a scalar under a bulk prefix): drift's copy
            // stands, nothing to union. Safe to drop the prefs duplicate.
            report.alreadyPresent++;
            await prefs.remove(key);
            continue;
          }
          if (merged == existing) {
            // Prefs added nothing new; drift is already a superset.
            report.alreadyPresent++;
            await prefs.remove(key);
            continue;
          }
          await write(key, merged);
          final readBack = await read(key);
          if (readBack != merged) {
            report.failed++;
            appLogger.error(
              'Blob merge FAILED for $key: wrote ${merged.length} chars, '
              'read back ${readBack?.length ?? "null"}. Prefs copy left intact.',
              tag: 'Storage',
            );
            continue;
          }
          await prefs.remove(key);
          report.merged++;
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
      '${report.merged} merged, '
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

  /// Unions the [prefs] copy of a bulk key into the [drift] copy by element
  /// identity, keeping drift's entries where both hold the same one.
  ///
  /// All bulk families store a JSON list of objects (messages keyed by
  /// `messageId`, contacts by `publicKey`); identity falls back to the object's
  /// canonical form so an id-less element is never dropped. Order is drift's
  /// list followed by the prefs-only elements, which mirrors how the stores
  /// append on save.
  ///
  /// Returns null when either side is not a JSON list of objects (a scalar
  /// under a bulk prefix), signalling the caller to leave drift's copy as-is.
  /// Returns the drift JSON unchanged when prefs contributes nothing new.
  static String? _mergeBulk(String drift, String prefs) {
    final List<dynamic> driftList;
    final List<dynamic> prefsList;
    try {
      final d = jsonDecode(drift);
      final p = jsonDecode(prefs);
      if (d is! List || p is! List) return null;
      driftList = d;
      prefsList = p;
    } catch (_) {
      return null;
    }

    String idOf(dynamic e) {
      if (e is Map) {
        final id = e['messageId'];
        if (id is String && id.isNotEmpty) return 'm:$id';
        final pk = e['publicKey'];
        if (pk is String && pk.isNotEmpty) return 'p:$pk';
      }
      // No stable id: fall back to the element's canonical JSON so distinct
      // elements stay distinct and true duplicates collapse.
      return 'j:${jsonEncode(e)}';
    }

    final seen = <String>{for (final e in driftList) idOf(e)};
    final result = List<dynamic>.from(driftList);
    for (final e in prefsList) {
      if (seen.add(idOf(e))) result.add(e);
    }
    if (result.length == driftList.length) return drift;
    return jsonEncode(result);
  }
}

/// Mutable tally of a migration run; surfaced in the log and used by tests.
class MigrationReport {
  int migrated = 0;
  int merged = 0;
  int alreadyPresent = 0;
  int skipped = 0;
  int failed = 0;
  int bytes = 0;

  bool get hadFailures => failed > 0;
}
