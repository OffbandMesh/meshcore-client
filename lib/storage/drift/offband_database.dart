import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

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
      // The DB directory is PINNED (see _pinnedDatabaseDirectory): a constant
      // path that never depends on the exe's version metadata or launch
      // location, so builds cannot diverge onto different databases (#363).
      // This also keeps the file out of the Documents/OneDrive dir (the native
      // default), where syncing a live SQLite file risks lock contention and
      // corruption. path_provider has no web implementation, so this only
      // applies off web; web ignores databaseDirectory and uses OPFS/IndexedDB.
      native: DriftNativeOptions(databaseDirectory: _pinnedDatabaseDirectory),
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

  /// Resolves the ONE fixed directory the database lives in, and migrates a DB
  /// left in an older location by a previous build into it.
  ///
  /// The path is pinned so it never depends on the executable's version
  /// metadata or launch location (#363). `getApplicationSupportDirectory()` on
  /// Windows derives the folder from the exe's embedded Company/Product
  /// strings, so two builds - or a future rebrand - would read DIFFERENT
  /// databases and the history would appear to vanish. On Windows the DB is
  /// therefore pinned to `%APPDATA%\Offband MeshCore`, a constant.
  ///
  /// On first run at the pinned location, the richest `offband_store.sqlite`
  /// from the old locations (the metadata-derived support dir; the
  /// documents/OneDrive dir; the earlier nested support path) is copied in - a
  /// copy, never a move: the source is left intact so nothing is stranded if
  /// anything goes wrong.
  static Future<Directory> _pinnedDatabaseDirectory() async {
    final dir = await _resolvePinnedDir();
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final target = p.join(dir.path, '$_dbName.sqlite');
    if (!File(target).existsSync()) {
      try {
        await _importRichestLegacyDatabase(target);
      } catch (e) {
        // Best-effort: on failure every SOURCE is left intact and any partial
        // destination is rolled back, so drift opens a fresh DB and the old
        // data stays recoverable. Loud, never silent (SAFELANE 6).
        appLogger.error(
          'Failed to migrate an existing drift DB into the pinned directory '
          '($target): $e. Sources are intact; a fresh DB will open here and the '
          'old data remains recoverable.',
          tag: 'Storage',
        );
      }
    }

    return dir;
  }

  /// The fixed directory: `<data root>/Offband MeshCore`, a constant.
  ///
  /// Windows uses `%APPDATA%`. Linux is pinned too, because its support dir
  /// derives from the executable NAME and so has the same divergence bug this
  /// fixes; it uses `$XDG_DATA_HOME` (or `~/.local/share`). macOS is left on
  /// `getApplicationSupportDirectory()`, which is keyed by the stable bundle id.
  static Future<Directory> _resolvePinnedDir() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory(p.join(appData, _pinnedFolder));
      }
    }
    if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final home = Platform.environment['HOME'];
      final base = (xdg != null && xdg.isNotEmpty)
          ? xdg
          : (home != null && home.isNotEmpty
                ? p.join(home, '.local', 'share')
                : null);
      if (base != null) return Directory(p.join(base, _pinnedFolder));
    }
    return getApplicationSupportDirectory();
  }

  static const String _pinnedFolder = 'Offband MeshCore';

  /// Snapshots the legacy DB (chosen from the known and scanned locations) into
  /// [target] (which must not yet exist), leaving the source intact. A no-op on
  /// a fresh install where no legacy DB exists.
  static Future<void> _importRichestLegacyDatabase(String target) async {
    // Prefer the KNOWN canonical locations in priority order: these are where a
    // normal prior build wrote (the metadata-derived support dir, then the
    // documents/OneDrive dir the first builds used). Using them directly avoids
    // the size heuristic picking a larger-but-junk DB from some other build.
    final known = <String>[];
    try {
      final support = await getApplicationSupportDirectory();
      known.add(p.join(support.path, '$_dbName.sqlite'));
    } catch (_) {}
    try {
      final docs = await getApplicationDocumentsDirectory();
      known.add(p.join(docs.path, '$_dbName.sqlite'));
    } catch (_) {}

    final scanned = _scanAppDataForDatabases()
        .where((c) => c != target)
        .toList();
    final source = chooseMigrationSource(
      known.where((c) => c != target).toList(),
      scanned,
    );
    if (source == null) return; // fresh install, nothing to migrate

    snapshotDatabase(source, target);
    appLogger.info(
      'Migrated drift DB into the pinned directory: $source -> $target '
      '(source left intact)',
      tag: 'Storage',
    );
  }

  /// Writes a consistent snapshot of the [source] DB to [target] via SQLite
  /// `VACUUM INTO`, which takes a read transaction and so produces a correct
  /// snapshot even if the source is being written by another process (an old
  /// build left running) - the failure mode a raw file copy of a live WAL
  /// database has (Gemini review).
  ///
  /// On ANY failure it deletes the partial output and RETHROWS - it does NOT
  /// fall back to a file copy. VACUUM most often fails precisely because a
  /// writer holds a lock, which is exactly when a raw copy would be unsafe, so
  /// the safe move is to abort: the source is untouched and drift opens a fresh
  /// DB, keeping the history recoverable.
  ///
  /// The source's main and `-wal` files are not written; SQLite may create or
  /// touch the temporary `-shm` file next to the source when opening a WAL DB.
  /// Visible for testing.
  @visibleForTesting
  static void snapshotDatabase(String source, String target) {
    try {
      final db = sqlite3.open(source, mode: OpenMode.readOnly);
      try {
        db.execute("VACUUM INTO '${target.replaceAll("'", "''")}'");
      } finally {
        db.close();
      }
      final out = File(target);
      if (!out.existsSync() || out.lengthSync() == 0) {
        throw StateError('VACUUM INTO produced no output at $target');
      }
    } catch (_) {
      final out = File(target);
      if (out.existsSync()) {
        try {
          out.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Bounded scan of the app-data roots for the DB file, so one left by a build
  /// whose folder name we do not know (its metadata differed) is still found.
  static List<String> _scanAppDataForDatabases() {
    final roots = <Directory>[];
    for (final env in const ['APPDATA', 'LOCALAPPDATA']) {
      final root = Platform.environment[env];
      if (root == null || root.isEmpty) continue;
      final dir = Directory(root);
      if (dir.existsSync()) roots.add(dir);
    }
    return findDatabaseFiles(roots, '$_dbName.sqlite');
  }

  /// Depth-limited, entry-capped search of [roots] for files named [fileName].
  ///
  /// No directory-name blocklist: a build's data can legitimately sit under a
  /// folder named after ANY company string (e.g. `%APPDATA%\Microsoft\...` for
  /// a runner that never set custom metadata), so skipping by name would lose
  /// exactly the data this migration exists to preserve. Instead the walk is
  /// bounded by [maxDepth] and a hard [maxEntries] visit cap so a pathological
  /// tree (a folder with hundreds of thousands of files, a slow network drive)
  /// cannot stall startup. Symlinks are not followed, so it cannot cycle;
  /// unreadable directories are skipped. Visible for testing.
  @visibleForTesting
  static List<String> findDatabaseFiles(
    List<Directory> roots,
    String fileName, {
    int maxDepth = 2,
    int maxEntries = 50000,
  }) {
    final found = <String>[];
    var visited = 0;

    void walk(Directory dir, int depth) {
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return; // permission denied etc.
      }
      for (final e in entries) {
        if (visited++ >= maxEntries) return;
        if (e is File) {
          if (p.basename(e.path) == fileName) found.add(e.path);
        } else if (e is Directory && depth < maxDepth) {
          walk(e, depth + 1);
        }
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    return found;
  }

  /// Picks the DB to migrate: the first existing, non-empty path in
  /// [knownInPriority] (the canonical locations a normal prior build wrote to),
  /// else the largest DB in [scanned] (the unknown-folder fallback).
  ///
  /// Preferring the known locations stops a larger-but-junk DB from some other
  /// build (a size-heuristic misfire) from beating the real one. Visible for
  /// testing.
  @visibleForTesting
  static String? chooseMigrationSource(
    List<String> knownInPriority,
    List<String> scanned,
  ) {
    for (final k in knownInPriority) {
      final f = File(k);
      if (f.existsSync() && f.lengthSync() > 0) return k;
    }
    return richestExisting(scanned);
  }

  /// Returns the existing, non-empty candidate path with the LARGEST main file,
  /// or null if none exist. Choosing by size guarantees a small/fresh DB never
  /// wins over one holding real history. Visible for testing.
  @visibleForTesting
  static String? richestExisting(List<String> candidatePaths) {
    String? best;
    int bestSize = 0;
    for (final path in candidatePaths) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final size = f.lengthSync();
      if (size > bestSize) {
        bestSize = size;
        best = path;
      }
    }
    return best;
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
