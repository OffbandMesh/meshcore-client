import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/store_consolidation_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:sqlite3/sqlite3.dart';

/// #367: union message stores left in other locations into the current store,
/// so a user with data split across differently-built copies loses nothing.
void main() {
  late OffbandDatabase db;
  late BlobStore store;
  late Directory tmp;

  setUp(() {
    db = OffbandDatabase(NativeDatabase.memory());
    store = BlobStore(db);
    BlobStore.overrideForTest(store);
    tmp = Directory.systemTemp.createTempSync('consolidate_test');
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  // Writes a real drift-shaped store file with the given blobs.
  String makeStore(String name, Map<String, String> blobs) {
    final path = '${tmp.path}/$name/offband_store.sqlite';
    Directory('${tmp.path}/$name').createSync(recursive: true);
    final sdb = sqlite3.open(path);
    sdb.execute('CREATE TABLE stored_blobs(key TEXT PRIMARY KEY, value TEXT)');
    final stmt = sdb.prepare(
      'INSERT INTO stored_blobs(key, value) VALUES(?, ?)',
    );
    blobs.forEach((k, v) => stmt.execute([k, v]));
    stmt.close();
    sdb.close();
    return path;
  }

  group('mergeBlob', () {
    const key = 'channel_messages_devpsk_a';

    test('writes when the key is absent', () async {
      expect(await store.mergeBlob(key, '[{"messageId":"a"}]'), isTrue);
      expect(await store.read(key), '[{"messageId":"a"}]');
    });

    test('unions by id, keeping existing and adding missing', () async {
      await store.write(key, '[{"messageId":"a"},{"messageId":"b"}]');
      expect(
        await store.mergeBlob(key, '[{"messageId":"b"},{"messageId":"c"}]'),
        isTrue,
      );
      expect(
        await store.read(key),
        '[{"messageId":"a"},{"messageId":"b"},{"messageId":"c"}]',
      );
    });

    test('reports no change when the incoming is a subset', () async {
      await store.write(key, '[{"messageId":"a"},{"messageId":"b"}]');
      expect(await store.mergeBlob(key, '[{"messageId":"a"}]'), isFalse);
      expect(await store.read(key), '[{"messageId":"a"},{"messageId":"b"}]');
    });

    // Identity-edge coverage for the merge logic Gemini flagged as unverified.
    // _mergeBulk resolves identity in this order: messageId, then publicKey,
    // then the object's canonical JSON. On a collision the CURRENT copy is
    // kept and only unseen incoming items are appended. These pin each branch.

    test(
      'identity falls back to publicKey (contacts) when no messageId',
      () async {
        const ck = 'contacts_dev';
        await store.write(ck, '[{"publicKey":"A","name":"current"}]');
        // Same pk A (kept as-is), new pk B (added).
        expect(
          await store.mergeBlob(
            ck,
            '[{"publicKey":"A","name":"stale"},{"publicKey":"B"}]',
          ),
          isTrue,
        );
        expect(
          await store.read(ck),
          '[{"publicKey":"A","name":"current"},{"publicKey":"B"}]',
        );
      },
    );

    test(
      'keeps the current copy on an id collision (an edit does not win)',
      () async {
        await store.write(key, '[{"messageId":"a","text":"orig"}]');
        // Same messageId, different text: the current copy must survive, and the
        // merge reports no change.
        expect(
          await store.mergeBlob(key, '[{"messageId":"a","text":"edited"}]'),
          isFalse,
        );
        expect(await store.read(key), '[{"messageId":"a","text":"orig"}]');
      },
    );

    test('id-less objects dedupe by whole-object identity', () async {
      await store.write(key, '[{"text":"hi","ts":1}]');
      // Identical object deduped; a differing one appended.
      expect(
        await store.mergeBlob(
          key,
          '[{"text":"hi","ts":1},{"text":"yo","ts":2}]',
        ),
        isTrue,
      );
      expect(
        await store.read(key),
        '[{"text":"hi","ts":1},{"text":"yo","ts":2}]',
      );
    });

    test('id-less dedupe is independent of key order', () async {
      // Two stores from different builds can serialise the same object with
      // keys in a different order; that must still dedupe, not duplicate.
      await store.write(key, '[{"ts":1,"text":"a"}]');
      expect(
        await store.mergeBlob(key, '[{"text":"a","ts":1},{"text":"b","ts":2}]'),
        isTrue,
      );
      // The reordered duplicate collapsed; only the genuinely new object added.
      expect(
        await store.read(key),
        '[{"ts":1,"text":"a"},{"text":"b","ts":2}]',
      );
    });
  });

  group('pathsNeedingMerge (re-runs when stores appear or grow)', () {
    test('includes new and changed paths, skips unchanged', () {
      final prior = {'a': '1:100', 'b': '2:200'};
      // a unchanged, b changed (an old build grew it), c is new.
      final current = {'a': '1:100', 'b': '9:999', 'c': '3:300'};
      final need = StoreConsolidationService.pathsNeedingMerge(prior, current)
        ..sort();
      expect(need, ['b', 'c']);
    });

    test('is empty when nothing changed (cheap no-op startup)', () {
      final sigs = {'a': '1:1', 'b': '2:2'};
      expect(StoreConsolidationService.pathsNeedingMerge(sigs, sigs), isEmpty);
    });
  });

  group('consolidateStores', () {
    test(
      'unions messages from every other store into the current one',
      () async {
        const key = 'channel_messages_devpsk_public';
        // Current store already holds a, b.
        await store.write(key, '[{"messageId":"a"},{"messageId":"b"}]');

        // Two stranded stores: one adds c (and re-states b), one adds d, plus a
        // non-bulk key that must be ignored.
        final s1 = makeStore('one', {
          key: '[{"messageId":"b"},{"messageId":"c"}]',
        });
        final s2 = makeStore('two', {
          key: '[{"messageId":"d"}]',
          'ui_sort_option': 'manual', // not a bulk key
        });

        final result = await StoreConsolidationService.consolidateStores([
          s1,
          s2,
        ]);

        expect(result.stores, 2);
        expect(
          await store.read(key),
          '[{"messageId":"a"},{"messageId":"b"},'
          '{"messageId":"c"},{"messageId":"d"}]',
        );
        // The non-bulk key was not imported.
        expect(await store.read('ui_sort_option'), isNull);
      },
    );

    test('skips an unreadable store without failing', () async {
      final good = makeStore('good', {'contacts_dev': '[{"publicKey":"A"}]'});
      final missing = '${tmp.path}/gone/offband_store.sqlite';

      final result = await StoreConsolidationService.consolidateStores([
        missing,
        good,
      ]);

      expect(result.stores, 1, reason: 'only the readable store counted');
      expect(result.unmerged, contains(missing), reason: 'retried next launch');
      expect(await store.read('contacts_dev'), '[{"publicKey":"A"}]');
    });

    test(
      'skips corrupt / zero-byte / schemaless stores, merges the valid one',
      () async {
        // Zero-byte file.
        final empty = '${tmp.path}/empty/offband_store.sqlite';
        Directory('${tmp.path}/empty').createSync();
        File(empty).writeAsBytesSync(const []);
        // A valid SQLite file that lacks the stored_blobs table.
        final noTable = '${tmp.path}/notable/offband_store.sqlite';
        Directory('${tmp.path}/notable').createSync();
        final s = sqlite3.open(noTable);
        s.execute('CREATE TABLE other(x TEXT)');
        s.close();
        // Non-SQLite garbage bytes.
        final garbage = '${tmp.path}/garbage/offband_store.sqlite';
        Directory('${tmp.path}/garbage').createSync();
        File(garbage).writeAsBytesSync(List<int>.filled(64, 7));
        // One good store.
        final good = makeStore('good2', {
          'contacts_dev': '[{"publicKey":"Z"}]',
        });

        final result = await StoreConsolidationService.consolidateStores([
          empty,
          noTable,
          garbage,
          good,
        ]);

        expect(result.stores, 1, reason: 'only the valid store was read');
        expect(
          result.unmerged,
          containsAll([empty, noTable, garbage]),
          reason:
              'skipped stores are reported so they are retried, not stranded',
        );
        expect(await store.read('contacts_dev'), '[{"publicKey":"Z"}]');
      },
    );

    test('skips a store larger than the size guard', () async {
      // A store padded well past a small cap, and a tiny one under it.
      final bigVal =
          '[${List.generate(20000, (i) => '{"messageId":"m$i"}').join(',')}]';
      final big = makeStore('big', {'channel_messages_devpsk_big': bigVal});
      final small = makeStore('small', {'contacts_dev': '[{"publicKey":"A"}]'});
      final cap = File(small).lengthSync() + 1024;
      expect(File(big).lengthSync(), greaterThan(cap));

      final result = await StoreConsolidationService.consolidateStores([
        big,
        small,
      ], maxStoreBytes: cap);

      expect(result.stores, 1, reason: 'the oversized store was skipped');
      expect(result.unmerged, contains(big), reason: 'retried if it shrinks');
      expect(await store.read('contacts_dev'), '[{"publicKey":"A"}]');
      expect(await store.read('channel_messages_devpsk_big'), isNull);
    });
  });
}
