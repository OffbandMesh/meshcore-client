import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
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

  /// Proves the database opens and round-trips a write. Throws (or returns
  /// false) if storage is unusable, e.g. the native sqlite library can't load
  /// (#385). Used by the startup health probe.
  Future<bool> verifyReadWrite() => _db.verifyReadWrite();

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

  // ---------------------------------------------------------------------------
  // Per-message rows (#920)
  //
  // The blob API above keeps a whole history in one row, so every save paid for
  // every message that came before it. These methods work one message at a
  // time. They live on BlobStore rather than in a second class because both
  // APIs must use the SAME OffbandDatabase instance: opening the database twice
  // is an error on the web backends, and a second singleton would be one
  // mistake away from doing exactly that.
  // ---------------------------------------------------------------------------

  /// Inserts or updates [rows] under [storeKey] in one transaction.
  ///
  /// Upserts on `(storeKey, mergeKey)`, which is the same identity the blob
  /// merge deduped on, so saving a message that is already stored updates it
  /// instead of duplicating it. Cost is proportional to [rows], not to the
  /// history already stored, which is the entire point.
  Future<void> upsertMessageRows(
    String storeKey,
    Iterable<MessageRowInput> rows,
  ) async {
    if (rows.isEmpty) return;
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(
        _db.messageRecords,
        rows
            .map(
              (r) => MessageRecordsCompanion.insert(
                storeKey: storeKey,
                mergeKey: r.mergeKey,
                timestampMs: r.timestampMs,
                payload: r.payload,
              ),
            )
            .toList(),
      );
    });
  }

  /// The stored message payloads for [storeKey], oldest first.
  ///
  /// Ordering and paging happen in SQLite, so loading the most recent N no
  /// longer means decoding the whole history first. [limit] with no [offset]
  /// returns the NEWEST [limit] messages, still in oldest-first order, because
  /// that is what a chat screen opens with.
  Future<List<String>> messagePayloads(
    String storeKey, {
    int? limit,
    int? offset,
  }) async {
    final q = _db.select(_db.messageRecords)
      ..where((t) => t.storeKey.equals(storeKey));
    if (limit != null) {
      q.orderBy([
        (t) => OrderingTerm(expression: t.timestampMs, mode: OrderingMode.desc),
      ]);
      q.limit(limit, offset: offset);
      final newestFirst = await q.get();
      return newestFirst.reversed.map((r) => r.payload).toList();
    }
    q.orderBy([(t) => OrderingTerm(expression: t.timestampMs)]);
    final rows = await q.get();
    return rows.map((r) => r.payload).toList();
  }

  /// Every stored identity under [storeKey].
  ///
  /// The migration's readback gate asks this, not [messageRowCount], because
  /// the question that matters is whether any record from the blob is MISSING
  /// from rows. A total count cannot answer that once rows may legitimately
  /// hold messages the frozen blob does not (#952).
  Future<Set<String>> messageMergeKeys(String storeKey) async {
    final key = _db.messageRecords.mergeKey;
    final rows =
        await (_db.selectOnly(_db.messageRecords)
              ..addColumns([key])
              ..where(_db.messageRecords.storeKey.equals(storeKey)))
            .get();
    return rows.map((r) => r.read(key)!).toSet();
  }

  /// Which of [storeKey]'s blob records have no row, or **null** when that
  /// cannot be determined (#962).
  ///
  /// The migration gate's readback check, as a question anyone can ask without
  /// migrating anything. The sweep asks it again immediately before deleting a
  /// blob rather than trusting the marker, which is the difference between
  /// "we recorded that this migrated" and "we just confirmed it".
  ///
  /// Empty means every blob record is present as a row and the blob is
  /// genuinely redundant. **Null means the question could not be answered** -
  /// the blob would not decode - and a caller must treat that as a refusal,
  /// never as "nothing is missing". Those two are deliberately different
  /// values: conflating them is how a sweep would delete the one copy of an
  /// unreadable history.
  Future<List<String>?> missingFromRows(
    String storeKey,
    BlobToRowsCallback toRows,
  ) async {
    final blob = await readWithPrefsFallback(storeKey);
    if (blob == null || blob.isEmpty) return const [];

    final int sourceCount;
    final List<MessageRowInput> rows;
    try {
      // The converter's own output cannot be the measure of the converter.
      // `countJsonArrayElements` decodes the blob and does nothing but count,
      // in a separate `compute`, exactly as the migration gate does. Without
      // it a converter that silently dropped a record would report every
      // record it produced as present and this would delete the blob holding
      // the only copy of the one it dropped (Gemini review).
      sourceCount = await compute(countJsonArrayElements, blob);
      rows = await compute(toRows, blob);
    } catch (e) {
      appLogger.error(
        'Cannot verify $storeKey against its rows: its ${blob.length} char '
        'blob will not decode ($e). Treating this as unverifiable; the blob '
        'is kept.',
        tag: 'Storage',
      );
      return null;
    }

    if (rows.length != sourceCount) {
      appLogger.error(
        'Cannot verify $storeKey against its rows: its blob holds '
        '$sourceCount records but the converter produced ${rows.length}. '
        'Treating this as unverifiable; the blob is kept.',
        tag: 'Storage',
      );
      return null;
    }

    return _absentFrom(
      rows.map((r) => r.mergeKey),
      await messageMergeKeys(storeKey),
    );
  }

  /// Verifies [storeKey]'s stale blob against its rows and deletes it **only**
  /// if every record is accounted for, as one atomic step (#962).
  ///
  /// The verify and the delete have to hold the same per-key lock. Checking
  /// and then deleting through two separate calls leaves a window, and a
  /// delete decided on a stale answer is not recoverable (Gemini review). This
  /// also serialises the reclaim against [ensureMessageRowsMigrated] and
  /// [mergeOffThread], which take the same lock, so the sweep cannot run
  /// against a key mid-migration.
  ///
  /// `deleted` says whether a blob actually went, so the caller does not have
  /// to infer it. `missing` is null when the blob could not be verified at all
  /// and the key must be refused, empty when nothing was missing, and
  /// otherwise the records that have no row.
  ///
  /// Nothing inside the locked section may take the same lock again: the chain
  /// is not re-entrant and would deadlock. Everything called here reads.
  Future<({bool deleted, List<String>? missing})> reclaimVerifiedHistoryBlob(
    String storeKey,
    BlobToRowsCallback toRows,
  ) {
    return synchronized(storeKey, () async {
      if (await read(storeKey) == null) {
        return (deleted: false, missing: const <String>[]);
      }
      final missing = await missingFromRows(storeKey, toRows);
      if (missing == null || missing.isNotEmpty) {
        return (deleted: false, missing: missing);
      }
      await delete(storeKey);
      return (deleted: true, missing: const <String>[]);
    });
  }

  /// The one place the "no blob record is missing from rows" rule lives.
  ///
  /// Both the migration gate and the sweep decide by this. The gate cannot
  /// just call [missingFromRows], because it has already decoded the blob and
  /// a second `compute` over multiple megabytes on the migration path would
  /// cost more than the duplication saves. Sharing the comparison keeps the
  /// RULE single even though the decode is not.
  static List<String> _absentFrom(
    Iterable<String> wanted,
    Set<String> stored,
  ) => wanted.where((k) => !stored.contains(k)).toSet().toList();

  /// The database's size in bytes, from SQLite itself.
  ///
  /// `page_count * page_size` rather than the file length, so it works for an
  /// in-memory database in tests and does not need the file path. It counts
  /// free pages, which is the point: it is what shows that a `DELETE` alone
  /// reclaims nothing.
  Future<int> databaseSizeBytes() async {
    Future<int> pragma(String name) async {
      final row = await _db.customSelect('PRAGMA $name').getSingle();
      return row.data.values.first as int;
    }

    return (await pragma('page_count')) * (await pragma('page_size'));
  }

  /// Rebuilds the database, returning free pages to the filesystem.
  ///
  /// Required: deleting rows marks pages free for reuse and does not shrink
  /// anything. Measured on the owner's database, deleting all 40 migrated
  /// blobs moved the file from 74,350,592 bytes to 74,350,592 bytes.
  ///
  /// It removes nothing of its own. Verified against a copy of a real
  /// database: 291 kept keys including all 98 unmigrated history blobs came
  /// through hash-identical, with the row count unchanged.
  Future<void> vacuum() => _db.customStatement('VACUUM');

  /// Every stored message, across every key.
  ///
  /// For the clear-confirmation dialog, which has to say what is NOT being
  /// deleted (#962).
  Future<int> totalMessageRows() async {
    final count = _db.messageRecords.mergeKey.count();
    final row = await (_db.selectOnly(
      _db.messageRecords,
    )..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// How many messages are stored under [storeKey].
  Future<int> messageRowCount(String storeKey) async {
    final count = _db.messageRecords.mergeKey.count();
    final row =
        await (_db.selectOnly(_db.messageRecords)
              ..addColumns([count])
              ..where(_db.messageRecords.storeKey.equals(storeKey)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Removes one message. O(1), with no history rewrite.
  Future<void> deleteMessageRow(String storeKey, String mergeKey) async {
    await (_db.delete(_db.messageRecords)..where(
          (t) => t.storeKey.equals(storeKey) & t.mergeKey.equals(mergeKey),
        ))
        .go();
  }

  /// Removes every message under [storeKey], for the stores' clear paths.
  Future<void> deleteMessageRows(String storeKey) async {
    await (_db.delete(
      _db.messageRecords,
    )..where((t) => t.storeKey.equals(storeKey))).go();
  }

  /// Store keys that already have rows, so a caller can tell a migrated key
  /// from one still on the blob path without reading any payloads.
  Future<Set<String>> messageStoreKeys() async {
    final key = _db.messageRecords.storeKey;
    final rows =
        await (_db.selectOnly(_db.messageRecords)
              ..addColumns([key])
              ..groupBy([key]))
            .get();
    return rows.map((r) => r.read(key)!).toSet();
  }

  /// Holds the set of store keys whose blob has been moved into rows.
  ///
  /// A separate marker rather than "this key has rows" because those are not
  /// the same statement. A key can have rows and an incomplete migration at
  /// the same time, and treating rows as proof of completeness is how a
  /// half-migrated history would read as a whole one.
  static const String migratedMarkerKey = '__msgrows_migrated';

  Set<String>? _migratedKeys;

  Future<Set<String>> _loadMigratedKeys() async {
    if (_migratedKeys != null) return _migratedKeys!;
    final raw = await read(migratedMarkerKey);
    if (raw == null || raw.isEmpty) return _migratedKeys = <String>{};
    try {
      return _migratedKeys = (jsonDecode(raw) as List<dynamic>)
          .cast<String>()
          .toSet();
    } catch (e) {
      // Refuse to guess. An unreadable marker means every key is treated as
      // unmigrated, which is the safe direction: the blobs are all still there.
      appLogger.error(
        'Could not decode the row-migration marker, treating every key as '
        'unmigrated (the blobs are intact): $e',
        tag: 'Storage',
      );
      return _migratedKeys = <String>{};
    }
  }

  Future<void> _markMigrated(String storeKey) async {
    await synchronized(migratedMarkerKey, () async {
      final keys = await _loadMigratedKeys();
      if (keys.contains(storeKey)) return;
      keys.add(storeKey);
      await write(migratedMarkerKey, jsonEncode(keys.toList()));
    });
    await _stampMigratedAt(storeKey);
  }

  /// Whether [storeKey] reads from rows. False means its blob is still the
  /// source of truth.
  Future<bool> isOnMessageRows(String storeKey) async =>
      (await _loadMigratedKeys()).contains(storeKey);

  @visibleForTesting
  void resetMigratedKeyCache() {
    _migratedKeys = null;
    _migratedAt = null;
  }

  /// When each migrated key migrated, as epoch milliseconds (#962).
  ///
  /// Deliberately a SECOND blob rather than reshaping [migratedMarkerKey] into
  /// a map. That marker is read on every save and every load through
  /// [_loadMigratedKeys]'s cache, so changing its shape would put a migration
  /// of its own on the hottest storage path. These timestamps are read only by
  /// the once-per-launch sweep, which is cold. Owner decision 2026-10-22.
  static const String migratedAtKey = '__msgrows_migrated_at';

  Map<String, int>? _migratedAt;

  Future<Map<String, int>> _loadMigratedAt() async {
    if (_migratedAt != null) return _migratedAt!;
    final raw = await read(migratedAtKey);
    if (raw == null || raw.isEmpty) return _migratedAt = <String, int>{};
    try {
      return _migratedAt = (jsonDecode(raw) as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as int),
      );
    } catch (e) {
      // Same safe direction as the marker: an unreadable file means no key has
      // a known migration time, so nothing is old enough to sweep and every
      // blob stays. Re-stamped on the next pass.
      appLogger.error(
        'Could not decode the row-migration timestamps, so no blob will be '
        'treated as stale (every blob is intact): $e',
        tag: 'Storage',
      );
      return _migratedAt = <String, int>{};
    }
  }

  Future<void> _stampMigratedAt(String storeKey, [DateTime? at]) async {
    await synchronized(migratedAtKey, () async {
      final stamps = await _loadMigratedAt();
      if (at == null && stamps.containsKey(storeKey)) return;
      stamps[storeKey] = (at ?? DateTime.now()).millisecondsSinceEpoch;
      await write(migratedAtKey, jsonEncode(stamps));
    });
  }

  /// A durable record of what each reclaim sweep deleted (#962).
  ///
  /// Why this exists rather than relying on the log: `appLogger` is gated on
  /// the app-debug-logging setting, which is **off by default**, so the only
  /// trail of an irreversible delete would not exist on a normal install. And
  /// the log previously recorded a count, never which keys went. "Cleared 40"
  /// is not an audit trail.
  ///
  /// Written into the database itself, so it survives restarts and the logging
  /// toggle, and can be read back without the app running.
  static const String reclaimAuditKey = '__msgrows_reclaim_audit';

  /// How many sweeps the audit keeps. A key is cleared once and then has no
  /// blob to consider again, so this operation is close to once per install
  /// and a handful of entries is a generous history rather than a stingy one.
  static const int reclaimAuditEntries = 5;

  /// Appends one sweep's outcome to the audit, oldest entries dropped.
  ///
  /// The key lists are stored in full: naming what was deleted is the entire
  /// point, and truncating them would recreate the "Cleared 40" problem.
  Future<void> appendReclaimAudit({
    required DateTime at,
    required List<String> cleared,
    required List<String> refused,
    required int bytesBefore,
    required int bytesAfter,
  }) async {
    await synchronized(reclaimAuditKey, () async {
      final entries = await reclaimAudit();
      entries.add({
        'at': at.toIso8601String(),
        'cleared': cleared,
        'refused': refused,
        'bytesBefore': bytesBefore,
        'bytesAfter': bytesAfter,
      });
      while (entries.length > reclaimAuditEntries) {
        entries.removeAt(0);
      }
      await write(reclaimAuditKey, jsonEncode(entries));
    });
  }

  /// The reclaim audit, oldest first. Empty when nothing has ever been swept.
  Future<List<Map<String, dynamic>>> reclaimAudit() async {
    final raw = await read(reclaimAuditKey);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .toList();
    } catch (e) {
      // An unreadable audit must not stop a sweep, and must not be silently
      // replaced either: it is logged and the next append starts a fresh list.
      appLogger.error(
        'Could not decode the reclaim audit; the next sweep starts a new '
        'one: $e',
        tag: 'Storage',
      );
      return <Map<String, dynamic>>[];
    }
  }

  /// When [storeKey] migrated to rows, or null if it has not or is unstamped.
  Future<DateTime?> messageRowsMigratedAt(String storeKey) async {
    final ms = (await _loadMigratedAt())[storeKey];
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Stamps any already-migrated key that has no timestamp, with [now].
  ///
  /// The backfill for installs that migrated before #962 shipped. Such a key
  /// is stamped on first sight rather than treated as eligible, so updating
  /// the app never deletes a blob on the spot: every key gets the full window
  /// measured from when we first knew about it. Returns the keys stamped.
  Future<List<String>> backfillMigratedAt({DateTime? now}) async {
    final marked = await _loadMigratedKeys();
    final stamps = await _loadMigratedAt();
    final missing = marked.where((k) => !stamps.containsKey(k)).toList()
      ..sort();
    for (final k in missing) {
      await _stampMigratedAt(k, now ?? DateTime.now());
    }
    if (missing.isNotEmpty) {
      appLogger.info(
        'Stamped ${missing.length} already-migrated key(s) with a migration '
        'time for the first time. Each starts its stale window from now, so '
        'nothing is swept on this launch.',
        tag: 'Storage',
      );
    }
    return missing;
  }

  @visibleForTesting
  Future<void> setMessageRowsMigratedAtForTest(String storeKey, DateTime at) =>
      _stampMigratedAt(storeKey, at);

  /// Moves [storeKey]'s blob into rows, once, and reports whether the key is
  /// now on rows (#920).
  ///
  /// Idempotent and safe to call on every save and load: a key already marked
  /// migrated returns immediately from an in-memory set.
  ///
  /// The gate, in order:
  ///
  /// 1. No blob, or an empty one, means there is nothing to move. The key is
  ///    marked migrated and starts on rows.
  /// 2. The blob's top-level element count is measured **independently of
  ///    [toRows]**, by a decode that does nothing but count. Asking the
  ///    converter how many records it saw would be a check that cannot fail;
  ///    the first version of this did exactly that and a deliberately lossy
  ///    converter sailed through it.
  /// 3. [toRows] decodes the blob **off the UI isolate**, because it is the
  ///    same multi-megabyte decode #919 moved. If it throws, nothing is
  ///    written and the key stays on the blob. It must return one row per
  ///    source element; a shortfall against step 2 refuses the migration.
  /// 4. The rows are inserted in one transaction, so a failure part-way leaves
  ///    no partial set behind.
  /// 5. The stored identities are read back and every DISTINCT merge key from
  ///    the blob must be among them. Rows BEYOND that set are fine.
  ///
  /// Steps 2 and 5 together close the loop from blob element to stored row,
  /// and either can fail on its own.
  ///
  /// Step 5 compared totals until #952. That was wrong in one direction: once
  /// a key is on rows its blob is frozen, so an earlier refused attempt or a
  /// newer message leaves rows the blob can never contain, the counts can
  /// never be brought level again, and the key is refused on every future
  /// attempt forever. Four of the owner's keys were stuck that way, including
  /// his two largest channels. "No blob record is missing" is the invariant
  /// that was actually wanted; it still catches a short insert, which is what
  /// the step is for.
  ///
  /// **The blob is never deleted**, not even on a verified match. Rows become
  /// the read and write path and the blob is left untouched. Reclaiming that
  /// space is deliberately a separate, owner-gated step: the moment the delete
  /// runs is the moment a mistake stops being recoverable.
  ///
  /// A mismatch keeps the key on the blob path, which still works, and says so
  /// loudly. It does not retry: a count that did not match once will not match
  /// on a loop, and a retry would just hammer the same keys.
  Future<bool> ensureMessageRowsMigrated(
    String storeKey,
    BlobToRowsCallback toRows,
  ) async {
    if (await isOnMessageRows(storeKey)) return true;

    return synchronized(storeKey, () async {
      // Re-check inside the lock: a concurrent save may have migrated it while
      // this call waited its turn.
      if (await isOnMessageRows(storeKey)) return true;

      final blob = await readWithPrefsFallback(storeKey);
      if (blob == null || blob.isEmpty) {
        await _markMigrated(storeKey);
        return true;
      }

      final int sourceCount;
      final List<MessageRowInput> rows;
      try {
        sourceCount = await compute(countJsonArrayElements, blob);
        rows = await compute(toRows, blob);
      } catch (e, stack) {
        appLogger.error(
          'Row migration of $storeKey FAILED while decoding its ${blob.length} '
          'char blob: $e. Nothing was written and the key still reads from the '
          'blob.\n$stack',
          tag: 'Storage',
        );
        return false;
      }

      if (rows.length != sourceCount) {
        appLogger.error(
          'Row migration of $storeKey REFUSED: the blob holds $sourceCount '
          'records but the converter produced ${rows.length} rows. Nothing '
          'was written. The blob is kept and still the source of truth.',
          tag: 'Storage',
        );
        return false;
      }

      final deduped = <String, MessageRowInput>{};
      for (final r in rows) {
        deduped[r.mergeKey] = r;
      }
      if (deduped.length != rows.length) {
        appLogger.warn(
          'Row migration of $storeKey: the blob held ${rows.length} records '
          'but only ${deduped.length} distinct identities, so '
          '${rows.length - deduped.length} were duplicates. Comparing against '
          'the distinct count.',
          tag: 'Storage',
        );
      }

      try {
        await upsertMessageRows(storeKey, deduped.values);
      } catch (e, stack) {
        appLogger.error(
          'Row migration of $storeKey FAILED while inserting '
          '${deduped.length} rows: $e. The blob is untouched and still the '
          'source of truth for this key.\n$stack',
          tag: 'Storage',
        );
        return false;
      }

      final storedKeys = await messageMergeKeys(storeKey);
      final missing = _absentFrom(deduped.keys, storedKeys);
      if (missing.isNotEmpty) {
        appLogger.error(
          'Row migration of $storeKey REFUSED: ${missing.length} of the '
          '${deduped.length} records in the blob are not present as rows after '
          'the insert (e.g. ${missing.take(3).join(', ')}). The blob is kept, '
          'nothing is deleted, and this key keeps reading from the blob.',
          tag: 'Storage',
        );
        return false;
      }

      // Rows beyond the blob's contents are expected, not a fault: once a key
      // is on rows the blob is frozen, so an earlier refused attempt or a
      // newer message leaves rows the blob will never contain. Comparing
      // TOTALS here is what trapped four of the owner's keys permanently
      // (#952), because the two numbers could never be brought back level.
      final extra = storedKeys.length - deduped.length;
      if (extra > 0) {
        appLogger.info(
          'Row migration of $storeKey: $extra row(s) beyond the '
          '${deduped.length} in the blob were already stored. Every blob '
          'record is present, so the migration stands.',
          tag: 'Storage',
        );
      }

      await _markMigrated(storeKey);
      appLogger.info(
        'Row migration of $storeKey: ${deduped.length} messages now stored as '
        'rows. The blob is retained untouched (#920).',
        tag: 'Storage',
      );
      return true;
    });
  }

  /// Read-modify-write for a bulk key with the decode, merge and re-encode run
  /// **off the UI isolate** (#919).
  ///
  /// Why this exists: the stores hold one JSON blob per key, so saving a single
  /// message decodes, rebuilds and re-encodes the entire history. Measured on
  /// the owner's live database, the largest channel is 5.38 MB holding 9,230
  /// messages, and one save costs **134 ms** on a desktop CPU (decode 50,
  /// rebuild 38, encode 51), scaling about 14 ms per 1,000 records. Saves on a
  /// key are serialised by [synchronized], so a burst of arriving messages pays
  /// that cost once each, back to back. Five messages on a phone five to ten
  /// times slower than a desktop crosses Android's five-second input-dispatch
  /// watchdog, which is what 25 ANR clusters on Play reported (#334).
  ///
  /// This does not make the work cheaper, only concurrent: the ~11 MB of string
  /// and map allocation per save still happens, on another isolate. Removing
  /// the cost needs one row per message (#920).
  ///
  /// [merge] **must be a top-level or static function**: `compute` sends it to
  /// another isolate, and a closure capturing `this` is not sendable. It
  /// receives `(storedJson, payload)` and returns the JSON to store, or null to
  /// leave the key untouched.
  ///
  /// [payload] is whatever single string the callback needs alongside the
  /// stored blob: the incoming batch as JSON when saving, the merge key of the
  /// record to drop when deleting. The callback defines its meaning; this
  /// method only carries it across the isolate boundary.
  ///
  /// Fails closed. If [merge] throws, including on malformed stored JSON, the
  /// error is logged and **the key is not written**, so a corrupt or
  /// undecodable blob can never be overwritten by a truncated one. This is the
  /// same refusal the stores already made inline; it does not fall back to
  /// merging on the UI isolate.
  ///
  /// On web `compute` runs [merge] inline, because web has no isolates. That is
  /// documented `compute` behaviour, not a silent degradation: web keeps the
  /// cost it has today and gains nothing here, which #920 fixes for every
  /// platform at once.
  ///
  /// Returns true when the key was written.
  Future<bool> mergeOffThread(
    String key,
    String payload,
    BlobMergeCallback merge,
  ) {
    return synchronized(key, () async {
      final stored = await readWithPrefsFallback(key);
      final String? merged;
      try {
        merged = await compute(merge, (stored, payload));
      } catch (e, stack) {
        appLogger.error(
          'Off-thread merge FAILED for $key (stored '
          '${stored?.length ?? "null"} chars, payload '
          '${payload.length} chars): $e. The key was NOT written, so '
          'nothing was truncated.\n$stack',
          tag: 'Storage',
        );
        return false;
      }
      if (merged == null) return false;
      await write(key, merged);
      return true;
    });
  }

  /// Unions an [incoming] bulk value into the stored value for [key] by element
  /// identity (message id / public key), keeping the stored copy on conflict and
  /// adding only what is missing. Used to consolidate stores found in old
  /// locations (#367). Serialised per key. Returns true if anything changed.
  Future<bool> mergeBlob(String key, String incoming) {
    return synchronized(key, () async {
      final current = await read(key);
      if (current == null) {
        await write(key, incoming);
        return true;
      }
      final merged = _mergeBulk(current, incoming);
      // null => not JSON lists (keep current); == current => nothing new.
      if (merged == null || merged == current) return false;
      await write(key, merged);
      return true;
    });
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
      // elements stay distinct and true duplicates collapse. Keys are sorted at
      // every level, so two objects that differ ONLY in key order (e.g. from
      // stores serialised by different builds) hash equal and do not duplicate.
      return 'j:${jsonEncode(_canonicalize(e))}';
    }

    final seen = <String>{for (final e in driftList) idOf(e)};
    final result = List<dynamic>.from(driftList);
    for (final e in prefsList) {
      if (seen.add(idOf(e))) result.add(e);
    }
    if (result.length == driftList.length) return drift;
    return jsonEncode(result);
  }

  /// Recursively rebuilds [value] with every map's keys in sorted order, so
  /// `jsonEncode` yields a key-order-independent form. Used only to compute the
  /// id-less identity above; the stored data itself is never reordered.
  static dynamic _canonicalize(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _canonicalize(value[k])};
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }
}

/// Counts the top-level elements of a JSON array, and nothing else.
///
/// Exists so [BlobStore.ensureMessageRowsMigrated] can learn how many records
/// a blob holds without asking the converter it is checking. Top-level so
/// `compute` can send it.
int countJsonArrayElements(String json) =>
    (jsonDecode(json) as List<dynamic>).length;

/// Turns one history blob into per-message rows, run on another isolate.
///
/// Must be a top-level or static function so `compute` can send it. Takes the
/// raw blob JSON and returns one [MessageRowInput] per message. Throwing is the
/// correct response to an undecodable blob: [BlobStore.ensureMessageRowsMigrated]
/// turns that into a refused migration and leaves the blob as the source of
/// truth.
typedef BlobToRowsCallback = List<MessageRowInput> Function(String blobJson);

/// One message on its way into [MessageRecords] (#920).
///
/// A plain record rather than a drift companion so the stores can build it
/// without importing the generated code, and so the merge key and timestamp
/// are named at the call site instead of being positional.
class MessageRowInput {
  const MessageRowInput({
    required this.mergeKey,
    required this.timestampMs,
    required this.payload,
  });

  final String mergeKey;
  final int timestampMs;
  final String payload;
}

/// Merge step for [BlobStore.mergeOffThread], run on another isolate.
///
/// Takes `(storedJson, payload)` and returns the JSON to store, or null to
/// leave the key untouched. Must be a top-level or static function so `compute`
/// can send it; a record of two strings crosses the boundary, so sendability is
/// not in question.
typedef BlobMergeCallback = String? Function((String?, String) input);

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
