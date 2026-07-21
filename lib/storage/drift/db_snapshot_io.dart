import 'package:sqlite3/sqlite3.dart';

/// Snapshots [source] to [target] with SQLite `VACUUM INTO` (a consistent,
/// transaction-based copy). Native only; isolated in its own file so the
/// `dart:ffi`-backed sqlite3 import never reaches the web build (#363).
void vacuumInto(String source, String target) {
  final db = sqlite3.open(source, mode: OpenMode.readOnly);
  try {
    db.execute("VACUUM INTO '${target.replaceAll("'", "''")}'");
  } finally {
    db.close();
  }
}

/// Reads every row of a store's `stored_blobs` table into a key→value map.
/// Native only (#367 consolidation reads other stores this way).
Map<String, String> readStoredBlobs(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final rows = db.select('SELECT key, value FROM stored_blobs');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  } finally {
    db.close();
  }
}
