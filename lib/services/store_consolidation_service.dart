import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/drift/blob_store.dart';
import '../storage/drift/offband_database.dart';
import '../storage/prefs_manager.dart';
import '../utils/app_logger.dart';
// sqlite3 (dart:ffi) is native-only; the conditional import keeps it out of the
// web build (#363/#367).
import '../storage/drift/db_snapshot_web.dart'
    if (dart.library.io) '../storage/drift/db_snapshot_io.dart';

/// Consolidation of message stores left in other locations (#367).
///
/// #363 pins the DB to one directory and migrates ONE prior store into it, but
/// a user who ran differently-built copies can have data split across several
/// stores. This unions the bulk blobs (messages by id, contacts by public key)
/// from every discovered store into the current one, so nothing shows as a gap.
///
/// Native-only, and it NEVER deletes a source. Runs in `main()` after the
/// prefs→drift migration and before the stores are read into memory, so the UI
/// sees the consolidated data.
///
/// It is NOT a one-shot: instead of a permanent done-flag, it records each
/// consolidated store's signature (mtime + size). A store that is new, or that
/// a stray older build has since GROWN, has a different signature and is merged
/// again on the next launch, so data added later is never stranded. A store
/// whose signature is unchanged is not re-read, keeping startup cheap.
class StoreConsolidationService {
  StoreConsolidationService._();

  static const _sigKey = 'store_consolidation_sigs_v1';

  /// Stores larger than this are skipped rather than read into memory, so a
  /// pathologically large file cannot stall startup. Well above any realistic
  /// message history; aging-out/archiving is a separate future feature.
  static const _defaultMaxStoreBytes = 200 * 1024 * 1024;

  static Future<void> run() async {
    // Web has a single OPFS/IndexedDB-backed store; there is nothing to scan,
    // and sqlite3 is unavailable there.
    if (kIsWeb) return;

    final prefs = PrefsManager.instance;
    try {
      final current = await OffbandDatabase.pinnedDatabasePath();
      final others = (await OffbandDatabase.discoverStorePaths())
          .where((path) => path != current && File(path).existsSync())
          .toSet();

      final prior = _readSignatures(prefs.getString(_sigKey));
      final currentSigs = {for (final path in others) path: _signatureOf(path)};
      final toMerge = pathsNeedingMerge(prior, currentSigs);
      if (toMerge.isEmpty) return; // nothing new or changed since last launch

      final result = await consolidateStores(toMerge);

      // Persist signatures ONLY for stores that were actually consolidated. A
      // store that was skipped (unreadable, or over the size guard) keeps no
      // signature, so it is retried on a later launch rather than stranded -
      // its data lands the moment it becomes readable or drops under the guard.
      final mergedSigs = <String, String>{
        for (final path in toMerge)
          if (!result.unmerged.contains(path)) path: currentSigs[path]!,
      };
      await prefs.setString(_sigKey, jsonEncode({...prior, ...mergedSigs}));
      appLogger.info(
        'Store consolidation: merged from ${result.stores} store(s), '
        '${result.changed} key(s) updated.',
        tag: 'Storage',
      );
    } catch (e) {
      // Signatures are NOT persisted on failure, so it retries next launch.
      // Sources are untouched, so no data is lost.
      appLogger.error(
        'Store consolidation failed: $e. Will retry next launch; no data lost.',
        tag: 'Storage',
      );
    }
  }

  /// The subset of [current] paths whose signature is new or differs from
  /// [prior] - i.e. stores that appeared or changed and must be (re)merged.
  /// Visible for testing.
  @visibleForTesting
  static List<String> pathsNeedingMerge(
    Map<String, String> prior,
    Map<String, String> current,
  ) => [
    for (final e in current.entries)
      if (prior[e.key] != e.value) e.key,
  ];

  /// Reads each store in [otherPaths] and unions its bulk blobs into the current
  /// [BlobStore]. A store over [maxStoreBytes], or one that cannot be read, is
  /// skipped and reported in `unmerged` (so the caller does not record it as
  /// done) - never fatal. Visible for testing.
  @visibleForTesting
  static Future<({int stores, int changed, Set<String> unmerged})>
  consolidateStores(
    Iterable<String> otherPaths, {
    int maxStoreBytes = _defaultMaxStoreBytes,
  }) async {
    var stores = 0, changed = 0;
    final unmerged = <String>{};
    for (final path in otherPaths) {
      final file = File(path);
      if (file.existsSync() && file.lengthSync() > maxStoreBytes) {
        appLogger.warn(
          'Consolidation: store $path is '
          '${(file.lengthSync() / 1024 / 1024).round()}MB, over the '
          '${(maxStoreBytes / 1024 / 1024).round()}MB guard; skipped to keep '
          'startup responsive.',
          tag: 'Storage',
        );
        unmerged.add(path);
        continue;
      }

      Map<String, String> blobs;
      try {
        blobs = readStoredBlobs(path);
      } catch (e) {
        appLogger.warn(
          'Consolidation: could not read store $path: $e (skipped)',
          tag: 'Storage',
        );
        unmerged.add(path);
        continue;
      }
      stores++;
      for (final entry in blobs.entries) {
        if (!BlobStore.isBulkKey(entry.key)) continue;
        if (await BlobStore.instance.mergeBlob(entry.key, entry.value)) {
          changed++;
        }
      }
    }
    return (stores: stores, changed: changed, unmerged: unmerged);
  }

  static Map<String, String> _readSignatures(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final e in decoded.entries) e.key as String: e.value as String,
        };
      }
    } catch (_) {}
    return {};
  }

  static String _signatureOf(String path) {
    final f = File(path);
    return '${f.lastModifiedSync().millisecondsSinceEpoch}:${f.lengthSync()}';
  }
}
