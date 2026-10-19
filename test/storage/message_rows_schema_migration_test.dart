import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #920: schema 1 -> 2 adds `message_records` and must not touch a single byte
/// of `stored_blobs`. Every existing install is on schema 1 with its whole
/// history in there, so this is the test that stands between a schema bump and
/// 41 MB of someone's messages.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  tearDown(BlobStore.clearTestOverride);

  /// A database that looks exactly like one an older build left behind: the v1
  /// table, real data in it, and `user_version` still 1 so drift runs the
  /// upgrade rather than creating everything fresh.
  QueryExecutor v1DatabaseWith(Map<String, String> blobs) {
    return NativeDatabase.memory(
      setup: (raw) {
        raw.execute(
          'CREATE TABLE stored_blobs ('
          'key TEXT NOT NULL, '
          'value TEXT NOT NULL, '
          "updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', "
          "CURRENT_TIMESTAMP) AS INTEGER)), "
          'PRIMARY KEY (key))',
        );
        for (final entry in blobs.entries) {
          final escaped = entry.value.replaceAll("'", "''");
          raw.execute(
            "INSERT INTO stored_blobs (key, value) VALUES ('${entry.key}', "
            "'$escaped')",
          );
        }
        raw.execute('PRAGMA user_version = 1');
      },
    );
  }

  test('upgrading from 1 to 2 keeps every blob byte-identical', () async {
    const history = '[{"messageId":"id1","text":"don\'t lose me"}]';
    final db = OffbandDatabase(
      v1DatabaseWith({
        'channel_messages_abc0123456psk_dead': history,
        'contacts': '[{"name":"someone"}]',
      }),
    );
    final blobs = BlobStore(db);

    // Opening is lazy; the first query is what triggers the migration.
    expect(await blobs.read('channel_messages_abc0123456psk_dead'), history);
    expect(await blobs.read('contacts'), '[{"name":"someone"}]');

    await db.close();
  });

  test('upgrading from 1 to 2 creates a usable message_records', () async {
    final db = OffbandDatabase(v1DatabaseWith({'contacts': '[]'}));
    final blobs = BlobStore(db);

    await blobs.upsertMessageRows('k', const [
      MessageRowInput(mergeKey: 'id:a', timestampMs: 1, payload: '{"a":1}'),
    ]);

    expect(await blobs.messagePayloads('k'), ['{"a":1}']);
    await db.close();
  });

  test('the upgraded database reports schema 2', () async {
    final db = OffbandDatabase(v1DatabaseWith({'contacts': '[]'}));

    // Forces the open, and therefore the migration.
    await BlobStore(db).read('contacts');
    final version = await db
        .customSelect('PRAGMA user_version')
        .getSingle()
        .then((r) => r.data.values.first as int);

    expect(version, 2);
    await db.close();
  });

  test('the store-key index exists after an upgrade', () async {
    final db = OffbandDatabase(v1DatabaseWith({'contacts': '[]'}));
    await BlobStore(db).read('contacts');

    final names = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'message_records'",
        )
        .get();

    expect(
      names.map((r) => r.data['name']),
      contains('idx_message_records_store_ts'),
      reason: 'without it, ORDER BY timestamp_ms scans the whole table',
    );
    await db.close();
  });

  test('a database created fresh at schema 2 also gets the index', () async {
    // onUpgrade does not run for a new database, so the index has to be
    // created in beforeOpen as well or a fresh install silently loses it.
    final db = OffbandDatabase(NativeDatabase.memory());
    await BlobStore(db).read('anything');

    final names = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'message_records'",
        )
        .get();

    expect(
      names.map((r) => r.data['name']),
      contains('idx_message_records_store_ts'),
    );
    await db.close();
  });
}
