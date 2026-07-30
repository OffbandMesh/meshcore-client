import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';

/// Step-1 gate for #335: the database must open, write and read back before
/// any user data is migrated into it.
///
/// This runs against an in-memory SQLite instance so it exercises the drift
/// layer and generated code on any host. It does NOT prove the per-platform
/// backends (native libs on desktop/mobile, WASM on web), those are proven by
/// building each target and by `verifyReadWrite()` at runtime.
void main() {
  late OffbandDatabase db;

  setUp(() => db = OffbandDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('opens, writes and reads back (the #335 gate)', () async {
    expect(await db.verifyReadWrite(), isTrue);
  });

  test('round-trips a payload larger than the 5 MiB localStorage cap', () async {
    // The web build currently stores through localStorage, capped at 5 MiB per
    // origin, while this install already holds ~7 MB. Proving a >5 MiB value
    // survives is the whole point of the migration.
    final big = 'x' * (6 * 1024 * 1024);
    await db
        .into(db.storedBlobs)
        .insertOnConflictUpdate(
          StoredBlobsCompanion.insert(key: 'big', value: big),
        );

    final row = await (db.select(
      db.storedBlobs,
    )..where((t) => t.key.equals('big'))).getSingle();

    expect(row.value.length, big.length);
  });

  test('upsert replaces rather than duplicating a key', () async {
    for (final v in ['first', 'second']) {
      await db
          .into(db.storedBlobs)
          .insertOnConflictUpdate(
            StoredBlobsCompanion.insert(key: 'k', value: v),
          );
    }

    final rows = await (db.select(
      db.storedBlobs,
    )..where((t) => t.key.equals('k'))).get();

    expect(rows, hasLength(1));
    expect(rows.single.value, 'second');
  });
}
