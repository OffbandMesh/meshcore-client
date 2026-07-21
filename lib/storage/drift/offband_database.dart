import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

part 'offband_database.g.dart';

/// Bulk data store (#335). Replaces SharedPreferences for message history,
/// contacts and discovered contacts.
///
/// SharedPreferences is a settings store, and using it for bulk data is what
/// causes #306: on Windows every mutation re-encodes and rewrites the entire
/// file synchronously, and on web it is backed by `localStorage`, which is
/// capped at 5 MiB per origin and is also synchronous. This install already
/// holds ~7 MB, so the web build cannot function at all today.
///
/// drift is used because it is the only option verified to cover all six
/// targets: native SQLite on Android, iOS, macOS, Windows and Linux, and
/// SQLite compiled to WebAssembly on web, where it stores through OPFS or
/// IndexedDB and runs in a worker rather than on the UI thread.
///
/// Settings stay in SharedPreferences. Only bulk data moves here.
@DriftDatabase(tables: [StoredBlobs])
class OffbandDatabase extends _$OffbandDatabase {
  OffbandDatabase([QueryExecutor? executor])
    : super(executor ?? _defaultExecutor());

  static const String _dbName = 'offband_store';

  /// `drift_flutter` selects the platform backend: native SQLite on desktop
  /// and mobile, WASM on web. `web:` names the assets that must be shipped for
  /// the web build (`sqlite3.wasm`, `drift_worker.js`).
  static QueryExecutor _defaultExecutor() {
    return driftDatabase(
      name: _dbName,
      // Native default is getApplicationDocumentsDirectory(), which on Windows
      // is the user's Documents folder — redirected into OneDrive on most
      // machines. A live SQLite file syncing to OneDrive risks lock contention
      // and corruption, and it is the wrong place for app data. Use the
      // application-support dir instead (%APPDATA% on Windows), where
      // SharedPreferences already lives. path_provider has no web
      // implementation, so this only applies off web; web ignores
      // databaseDirectory and uses OPFS/IndexedDB.
      native: DriftNativeOptions(
        databaseDirectory: _appSupportDatabaseDirectory,
      ),
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        // Filename matches the asset published by the drift release, which is
        // `drift_worker.js` — not the `drift_worker.dart.js` the older docs
        // name. Both assets are taken from the SAME drift release so they are
        // built against each other.
        driftWorker: Uri.parse('drift_worker.js'),
      ),
    );
  }

  /// Resolves the application-support directory, and relocates a database left
  /// in the old documents location by an earlier build.
  ///
  /// Builds before this fix opened the DB under getApplicationDocumentsDirectory
  /// (OneDrive on Windows). Existing installs already have data there, so this
  /// moves the file - and its `-wal` / `-shm` sidecars - to the new location on
  /// first run, once, before drift opens it. Never deletes the source without a
  /// successful move; a failed move leaves the old file so no data is stranded.
  static Future<Directory> _appSupportDatabaseDirectory() async {
    final support = await getApplicationSupportDirectory();
    final newPath = p.join(support.path, '$_dbName.sqlite');

    if (!File(newPath).existsSync()) {
      try {
        final docs = await getApplicationDocumentsDirectory();
        final oldPath = p.join(docs.path, '$_dbName.sqlite');
        if (File(oldPath).existsSync() && oldPath != newPath) {
          // Copy ALL files first, verify, and only then delete the sources.
          // Deleting per-file mid-loop (Gemini review) could strand the main
          // .sqlite in one place and its -wal in another if a later copy
          // failed, corrupting the DB. Copy-all-then-delete-all makes a
          // partial failure recoverable: the original stays intact and the
          // half-written destination is cleaned up.
          final suffixes = ['', '-wal', '-shm'];
          final present = suffixes
              .where((s) => File('$oldPath$s').existsSync())
              .toList();
          try {
            for (final s in present) {
              File('$oldPath$s').copySync('$newPath$s');
            }
            // Verify every copy exists with a matching size before deleting.
            for (final s in present) {
              final src = File('$oldPath$s');
              final dst = File('$newPath$s');
              if (!dst.existsSync() || dst.lengthSync() != src.lengthSync()) {
                throw StateError('copy verification failed for $newPath$s');
              }
            }
            for (final s in present) {
              File('$oldPath$s').deleteSync();
            }
            appLogger.info(
              'Relocated drift DB out of the documents dir (OneDrive on '
              'Windows) into the app-support dir: $oldPath -> $newPath',
              tag: 'Storage',
            );
          } catch (e) {
            // Roll back any partial destination so drift does not open a
            // half-copied DB; the original in the documents dir is untouched.
            for (final s in present) {
              final dst = File('$newPath$s');
              if (dst.existsSync()) {
                try {
                  dst.deleteSync();
                } catch (_) {}
              }
            }
            rethrow;
          }
        }
      } catch (e) {
        // Relocation is best-effort. On failure the ORIGINAL DB is left intact
        // in the documents dir (the destination was rolled back), so no data is
        // lost - drift opens a fresh DB at the support location and the user's
        // history remains recoverable from the old path. Loud, never silent.
        appLogger.error(
          'Failed to relocate the drift DB from the documents dir: $e. The '
          'original at the old path is intact; a fresh DB will open at the '
          'app-support location. Recover the old DB manually if needed.',
          tag: 'Storage',
        );
      }
    }

    return support;
  }

  @override
  int get schemaVersion => 1;

  /// Step-1 gate for #335: proves the database opens, writes and reads back on
  /// the current platform. Deliberately trivial - no user data is involved, so
  /// this can be run on every target before any migration is written.
  Future<bool> verifyReadWrite() async {
    const probeKey = '__offband_probe__';
    final probeValue = 'ok-${DateTime.now().microsecondsSinceEpoch}';

    await into(storedBlobs).insertOnConflictUpdate(
      StoredBlobsCompanion.insert(key: probeKey, value: probeValue),
    );

    final row = await (select(
      storedBlobs,
    )..where((t) => t.key.equals(probeKey))).getSingleOrNull();

    await (delete(storedBlobs)..where((t) => t.key.equals(probeKey))).go();

    return row?.value == probeValue;
  }
}

/// One row per stored blob, replacing one SharedPreferences key each.
///
/// Deliberately key/value for the first migration: it maps 1:1 onto the
/// existing store interfaces, so callers do not change and the migration is
/// verifiable row-for-row against the old keys. Relational tables for messages
/// and contacts are a later step, once this is proven and querying is wanted.
class StoredBlobs extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {key};
}
