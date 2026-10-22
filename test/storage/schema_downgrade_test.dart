import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #943: what happens when a build opens a database left by a NEWER build.
///
/// #917's plan claimed a downgrade still works because the blobs are retained.
/// The owner hit the opposite on 2026-10-20: his pre-#917 install would not
/// start against his migrated database. These tests pin down what actually
/// governs that, because the issue's own explanation ("drift refuses to open a
/// database whose user_version is newer") is wrong, and the real mechanism
/// points somewhere else entirely.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  tearDown(BlobStore.clearTestOverride);

  /// A database shaped like one a FUTURE build left behind: both of today's
  /// tables, real data, and `user_version` ahead of this binary's
  /// schemaVersion of 2.
  QueryExecutor databaseAtVersion(int userVersion, Map<String, String> blobs) {
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
        raw.execute(
          'CREATE TABLE message_records ('
          'store_key TEXT NOT NULL, '
          'merge_key TEXT NOT NULL, '
          'timestamp_ms INTEGER NOT NULL, '
          'payload TEXT NOT NULL, '
          'PRIMARY KEY (store_key, merge_key))',
        );
        for (final entry in blobs.entries) {
          final escaped = entry.value.replaceAll("'", "''");
          raw.execute(
            "INSERT INTO stored_blobs (key, value) VALUES ('${entry.key}', "
            "'$escaped')",
          );
        }
        raw.execute('PRAGMA user_version = $userVersion');
      },
    );
  }

  Future<int> userVersionOf(OffbandDatabase db) => db
      .customSelect('PRAGMA user_version')
      .getSingle()
      .then((r) => r.data.values.first as int);

  group('drift dispatches a downgrade through onUpgrade', () {
    test('a newer user_version is reported as hadUpgrade, not refused', () {
      // The fact the whole question rests on. drift has no "newer schema"
      // refusal: it compares the two numbers for INEQUALITY and routes both
      // directions into onUpgrade ("Schema version upgrades and downgrades
      // will both be run here"). So whether a downgrade works is decided by
      // OUR onUpgrade, not by drift.
      const downgrade = OpeningDetails(3, 2);
      expect(downgrade.hadUpgrade, isTrue);
      expect(downgrade.wasCreated, isFalse);
    });

    test('a strategy with no onUpgrade throws, which is what bit #943', () {
      // The pre-#917 build declared schemaVersion 1 and NO migration getter,
      // so it got exactly this default. That, and not a drift version check,
      // is why the owner's old install would not open his schema-2 database.
      final db = OffbandDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      expect(
        () => MigrationStrategy().onUpgrade(Migrator(db), 2, 1),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('this build against a database from a future schema', () {
    test('it opens without complaint, which is the real hazard', () async {
      // Our onUpgrade guards on `from < 2`, so a 3 -> 2 downgrade falls
      // straight through it. No throw: the database opens and reads fine,
      // which means a future schema bump does NOT inherit #943's loud
      // failure. It gets a silent one instead.
      final db = OffbandDatabase(
        databaseAtVersion(3, {'contacts': '[{"name":"someone"}]'}),
      );
      addTearDown(db.close);

      expect(await BlobStore(db).read('contacts'), '[{"name":"someone"}]');
    });

    test('and it stamps user_version BACKWARDS to 2', () async {
      // drift writes its own schemaVersion once migrations "ran". A database
      // carrying schema-3 data is now labelled schema 2, so the schema-3
      // build that wrote it will not run its own 2 -> 3 upgrade again, against
      // tables that already exist in their newer shape.
      final db = OffbandDatabase(databaseAtVersion(3, {'contacts': '[]'}));
      addTearDown(db.close);
      await BlobStore(db).read('contacts');

      expect(
        await userVersionOf(db),
        2,
        reason:
            'a silent version rewrite is worse than a refusal: it destroys the '
            'only record that this database has been through a newer build',
      );
    });
  });

  group('a normal upgrade still behaves', () {
    test('an equal version is neither a create nor an upgrade', () {
      // Guards the tests above: they only mean something if a matched version
      // takes neither branch, so onUpgrade is genuinely downgrade-only here.
      const same = OpeningDetails(2, 2);
      expect(same.hadUpgrade, isFalse);
      expect(same.wasCreated, isFalse);
    });

    test(
      'a fresh database lands on 2 and is not treated as a downgrade',
      () async {
        final db = OffbandDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await BlobStore(db).read('anything');

        expect(await userVersionOf(db), 2);
      },
    );
  });
}
