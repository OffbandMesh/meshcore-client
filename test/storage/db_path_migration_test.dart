import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:sqlite3/sqlite3.dart';

/// #363: the drift DB directory is pinned to one fixed location, and an existing
/// DB from an older/unknown location is migrated into it. These pin the
/// data-safety-critical helpers: choosing the richest source, finding a DB under
/// any folder name, and copying without stranding or truncating data.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dbpath_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String relPath, int bytes) {
    final f = File('${tmp.path}/$relPath')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 0));
    return f.path;
  }

  // listSync returns backslash paths on Windows; normalize both sides so the
  // comparison is separator-agnostic.
  String norm(String s) => s.replaceAll('\\', '/');
  List<String> normAll(List<String> xs) => xs.map(norm).toList();

  group('richestExisting', () {
    test('picks the largest existing candidate', () {
      final small = write('small.sqlite', 100);
      final big = write('big.sqlite', 5000);
      final medium = write('medium.sqlite', 1000);
      expect(OffbandDatabase.richestExisting([small, big, medium]), big);
    });

    test('ignores candidates that do not exist', () {
      final real = write('real.sqlite', 200);
      expect(
        OffbandDatabase.richestExisting(['${tmp.path}/nope.sqlite', real]),
        real,
      );
    });

    test('returns null when none exist (fresh install)', () {
      expect(
        OffbandDatabase.richestExisting([
          '${tmp.path}/a.sqlite',
          '${tmp.path}/b.sqlite',
        ]),
        isNull,
      );
    });

    test('a 0-byte DB never wins', () {
      final empty = write('empty.sqlite', 0);
      final real = write('real.sqlite', 300);
      expect(OffbandDatabase.richestExisting([empty, real]), real);
      expect(OffbandDatabase.richestExisting([empty]), isNull);
    });
  });

  group('findDatabaseFiles', () {
    test('finds the DB under ANY company folder, incl. "Microsoft"', () {
      // The exact case the old blocklist would have dropped: a runner with
      // default metadata writes under %APPDATA%\Microsoft\<product>\.
      final target = write(
        'Microsoft/Offband MeshCore/offband_store.sqlite',
        9,
      );
      final found = OffbandDatabase.findDatabaseFiles([
        tmp,
      ], 'offband_store.sqlite');
      expect(normAll(found), contains(norm(target)));
    });

    test('respects maxDepth (does not descend past the limit)', () {
      write('a/b/c/offband_store.sqlite', 9); // depth 3 from tmp
      final found = OffbandDatabase.findDatabaseFiles(
        [tmp],
        'offband_store.sqlite',
        maxDepth: 2,
      );
      expect(found, isEmpty);
    });

    test('finds a DB at the allowed depth', () {
      final target = write('company/product/offband_store.sqlite', 9);
      final found = OffbandDatabase.findDatabaseFiles(
        [tmp],
        'offband_store.sqlite',
        maxDepth: 2,
      );
      expect(normAll(found), contains(norm(target)));
    });

    test('stops at the entry cap rather than scanning unbounded', () {
      for (var i = 0; i < 50; i++) {
        write('dir/file$i.txt', 1);
      }
      write('dir/offband_store.sqlite', 9);
      // A tiny cap must return without walking everything (no throw, bounded).
      final found = OffbandDatabase.findDatabaseFiles(
        [tmp],
        'offband_store.sqlite',
        maxEntries: 5,
      );
      expect(found.length, lessThanOrEqualTo(1));
    });
  });

  group('chooseMigrationSource', () {
    test('prefers a known location over a larger scanned DB', () {
      final known = write('support/offband_store.sqlite', 100);
      final biggerJunk = write('elsewhere/offband_store.sqlite', 999999);
      expect(
        OffbandDatabase.chooseMigrationSource([known], [biggerJunk, known]),
        known,
        reason: 'a real DB at a known location beats a larger junk one',
      );
    });

    test('falls back to the largest scanned DB when no known one exists', () {
      final missing = '${tmp.path}/support/offband_store.sqlite';
      final small = write('a/offband_store.sqlite', 100);
      final big = write('b/offband_store.sqlite', 5000);
      expect(
        OffbandDatabase.chooseMigrationSource([missing], [small, big]),
        big,
      );
    });

    test('skips an empty known DB and uses the scan', () {
      final emptyKnown = write('support/offband_store.sqlite', 0);
      final scanned = write('b/offband_store.sqlite', 500);
      expect(
        OffbandDatabase.chooseMigrationSource([emptyKnown], [scanned]),
        scanned,
      );
    });

    test('returns null when nothing exists', () {
      expect(
        OffbandDatabase.chooseMigrationSource(['${tmp.path}/nope.sqlite'], []),
        isNull,
      );
    });
  });

  group('snapshotDatabase', () {
    test('VACUUM INTO round-trips real rows and leaves the source', () {
      final src = '${tmp.path}/real/offband_store.sqlite';
      Directory('${tmp.path}/real').createSync(recursive: true);
      final db = sqlite3.open(src);
      db.execute('CREATE TABLE stored_blobs(key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO stored_blobs VALUES('a','1'),('b','2')");
      db.close();

      final dst = '${tmp.path}/snap/offband_store.sqlite';
      Directory('${tmp.path}/snap').createSync();
      OffbandDatabase.snapshotDatabase(src, dst);

      final out = sqlite3.open(dst, mode: OpenMode.readOnly);
      final rows = out.select(
        'SELECT key, value FROM stored_blobs ORDER BY key',
      );
      out.close();
      expect(rows.map((r) => '${r['key']}=${r['value']}').toList(), [
        'a=1',
        'b=2',
      ]);
      expect(File(src).existsSync(), isTrue, reason: 'source untouched');
    });

    test('aborts (throws) and leaves no target on a non-DB source', () {
      // A garbage file is not a valid SQLite DB: VACUUM INTO must fail, the
      // partial target must be cleaned up, and the error must propagate rather
      // than fall back to any unsafe path.
      final src = write('garbage/offband_store.sqlite', 64);
      final dst = '${tmp.path}/snap2/offband_store.sqlite';
      Directory('${tmp.path}/snap2').createSync();

      expect(
        () => OffbandDatabase.snapshotDatabase(src, dst),
        throwsA(anything),
      );
      expect(File(dst).existsSync(), isFalse, reason: 'no partial left behind');
    });
  });
}
