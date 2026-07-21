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
