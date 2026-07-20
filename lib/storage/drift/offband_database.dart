import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

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

  /// `drift_flutter` selects the platform backend: native SQLite on desktop
  /// and mobile, WASM on web. `web:` names the assets that must be shipped for
  /// the web build (`sqlite3.wasm`, `drift_worker.dart.js`).
  static QueryExecutor _defaultExecutor() {
    return driftDatabase(
      name: 'offband_store',
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
