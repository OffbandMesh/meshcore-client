import 'dart:io';

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
/// start against his migrated database.
///
/// The issue's own explanation was wrong. drift has no "newer schema" refusal,
/// so the first group here pins what actually governs this. The owner's
/// decision on 2026-10-22 was that downgrades stay unsupported and must fail
/// loudly rather than silently, which the second group pins.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  tearDown(BlobStore.clearTestOverride);

  /// A database shaped like one a build at [userVersion] left behind, with
  /// both of today's tables and real data in the blob table.
  QueryExecutor databaseAtVersion(
    int userVersion,
    Map<String, String> blobs, {
    File? file,
  }) {
    void setup(dynamic raw) {
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
    }

    return file == null
        ? NativeDatabase.memory(setup: setup)
        : NativeDatabase(file, setup: setup);
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
      // will both be run here"). So whether a downgrade is caught is decided
      // by OUR onUpgrade, not by drift.
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

  group('this build refuses a database from a future schema', () {
    test('opening one throws OffbandSchemaDowngrade', () async {
      final db = OffbandDatabase(
        databaseAtVersion(3, {'contacts': '[{"name":"someone"}]'}),
      );
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {}
      });

      await expectLater(
        BlobStore(db).read('contacts'),
        throwsA(isA<OffbandSchemaDowngrade>()),
      );
    });

    test('and the message names both schemas and what to do', () {
      const e = OffbandSchemaDowngrade(
        from: 3,
        to: 2,
        databasePath: r'C:\somewhere\offband_store.sqlite',
      );
      final text = e.toString();

      expect(text, contains('schema 3'));
      expect(text, contains('only understands 2'));
      expect(text, contains('one-way'));
      expect(text, contains(r'C:\somewhere\offband_store.sqlite'));
    });

    test('a resolved path is optional, so web still gets a message', () {
      const e = OffbandSchemaDowngrade(from: 9, to: 2);
      expect(e.toString(), contains('schema 9'));
      expect(e.toString(), isNot(contains('Database:')));
    });

    test('and user_version is NOT rewritten backwards', () async {
      // The point of refusing rather than falling through. drift writes its
      // own schemaVersion only after migrations have run, so throwing keeps
      // the database's record of having been on a newer build. Before #943
      // this came back 2 and that evidence was gone.
      final dir = await Directory.systemTemp.createTemp('offband_downgrade');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/offband_store.sqlite');

      final db = OffbandDatabase(
        databaseAtVersion(3, {'contacts': '[]'}, file: file),
      );
      await expectLater(
        BlobStore(db).read('contacts'),
        throwsA(isA<OffbandSchemaDowngrade>()),
      );
      try {
        await db.close();
      } catch (_) {}

      // Read it back on a connection that declares no schema of its own.
      final raw = NativeDatabase(file);
      final probe = _Probe(raw);
      addTearDown(probe.close);
      expect(
        await probe
            .customSelect('PRAGMA user_version')
            .getSingle()
            .then((r) => r.data.values.first as int),
        3,
        reason: 'the refusal must leave the version alone',
      );
    });
  });

  group('a normal upgrade still behaves', () {
    test('an equal version is neither a create nor an upgrade', () {
      // Guards the group above: refusing a downgrade only means something if
      // a matched version takes neither branch.
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

    test('a real 1 to 2 upgrade is untouched by the new branch', () async {
      // The regression that matters: every existing install arrives here.
      final db = OffbandDatabase(
        NativeDatabase.memory(
          setup: (raw) {
            raw.execute(
              'CREATE TABLE stored_blobs (key TEXT NOT NULL, '
              'value TEXT NOT NULL, '
              "updated_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s', "
              "CURRENT_TIMESTAMP) AS INTEGER)), PRIMARY KEY (key))",
            );
            raw.execute(
              "INSERT INTO stored_blobs (key, value) VALUES ('contacts', "
              "'[{\"name\":\"keep me\"}]')",
            );
            raw.execute('PRAGMA user_version = 1');
          },
        ),
      );
      addTearDown(db.close);

      expect(await BlobStore(db).read('contacts'), '[{"name":"keep me"}]');
      expect(await userVersionOf(db), 2);
    });
  });
}

/// A drift database with no tables and no migration, for reading a PRAGMA off
/// a file without declaring a schema that would itself trigger a migration.
class _Probe extends GeneratedDatabase {
  _Probe(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  int get schemaVersion => 3;
}
