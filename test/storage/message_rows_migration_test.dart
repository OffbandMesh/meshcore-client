import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #920 B3: moving a history blob into rows. The gate matters more than the
/// move: every failure path here has to leave the blob as the source of truth,
/// because the blob is the only copy of someone's messages.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    blobs = BlobStore(db);
    BlobStore.overrideForTest(blobs);
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  String blobOf(List<int> ids) => jsonEncode([
    for (final i in ids) {'messageId': 'id$i', 'timestamp': 1000 + i},
  ]);

  test('moves a blob into rows and marks the key migrated', () async {
    await blobs.write('k', blobOf([1, 2, 3]));

    final ok = await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(ok, isTrue);
    expect(await blobs.messageRowCount('k'), 3);
    expect(await blobs.isOnMessageRows('k'), isTrue);
  });

  test('NEVER deletes the blob, even on a verified match', () async {
    final original = blobOf([1, 2]);
    await blobs.write('k', original);

    await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(
      await blobs.read('k'),
      original,
      reason: 'reclaiming the space is a separate owner-gated step (#920)',
    );
  });

  test('rows carry the payload through unchanged', () async {
    await blobs.write('k', blobOf([7]));

    await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(await blobs.messagePayloads('k'), [
      '{"messageId":"id7","timestamp":1007}',
    ]);
  });

  test('a second call is a no-op and does not re-import', () async {
    await blobs.write('k', blobOf([1, 2]));
    await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    // Something arrives and is saved as a row after the migration.
    await blobs.upsertMessageRows('k', const [
      MessageRowInput(mergeKey: 'id:new', timestampMs: 9999, payload: '{}'),
    ]);
    final ok = await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(ok, isTrue);
    expect(
      await blobs.messageRowCount('k'),
      3,
      reason: 'a repeat migration must not touch the rows that exist',
    );
  });

  test('an absent blob marks the key migrated with no rows', () async {
    final ok = await blobs.ensureMessageRowsMigrated('fresh', rowsFromTestBlob);

    expect(ok, isTrue);
    expect(await blobs.isOnMessageRows('fresh'), isTrue);
    expect(await blobs.messageRowCount('fresh'), 0);
  });

  test('an empty blob marks the key migrated with no rows', () async {
    await blobs.write('k', '');

    final ok = await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(ok, isTrue);
    expect(await blobs.isOnMessageRows('k'), isTrue);
  });

  group('failure paths all keep the blob authoritative', () {
    test('an undecodable blob refuses the migration', () async {
      const corrupt = '{not json at all';
      await blobs.write('k', corrupt);

      final ok = await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

      expect(ok, isFalse);
      expect(await blobs.isOnMessageRows('k'), isFalse);
      expect(await blobs.read('k'), corrupt);
      expect(await blobs.messageRowCount('k'), 0);
    });

    test('a decoder that throws refuses the migration', () async {
      await blobs.write('k', blobOf([1]));

      final ok = await blobs.ensureMessageRowsMigrated('k', _alwaysThrows);

      expect(ok, isFalse);
      expect(await blobs.isOnMessageRows('k'), isFalse);
      expect(await blobs.read('k'), blobOf([1]));
    });

    test('a decoder that drops records refuses on the count gate', () async {
      // The case the readback gate exists for: the decode "succeeded" but
      // produced fewer messages than the blob held. Marking this migrated
      // would silently shorten someone's history.
      await blobs.write('k', blobOf([1, 2, 3, 4, 5]));

      final ok = await blobs.ensureMessageRowsMigrated('k', _dropsOneRecord);

      expect(
        ok,
        isFalse,
        reason: 'fewer rows than records must never be accepted',
      );
      expect(await blobs.isOnMessageRows('k'), isFalse);
      expect(
        await blobs.read('k'),
        blobOf([1, 2, 3, 4, 5]),
        reason: 'the blob is the only copy of those messages',
      );
    });

    test('a refused key can still be read from its blob afterwards', () async {
      await blobs.write('k', blobOf([1, 2]));
      await blobs.ensureMessageRowsMigrated('k', _alwaysThrows);

      // The whole point of refusing rather than throwing: the app keeps
      // working on the old path.
      expect(await blobs.read('k'), blobOf([1, 2]));
      expect(await blobs.isOnMessageRows('k'), isFalse);
    });
  });

  test('duplicate identities in a blob are deduped, not refused', () async {
    // A blob built by the old merge should not contain duplicates, but the
    // legacy-key adoption path could have produced them. Comparing against
    // the DISTINCT count means that does not read as data loss.
    await blobs.write(
      'k',
      jsonEncode([
        {'messageId': 'id1', 'timestamp': 1001},
        {'messageId': 'id1', 'timestamp': 1001},
        {'messageId': 'id2', 'timestamp': 1002},
      ]),
    );

    final ok = await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    expect(ok, isTrue);
    expect(await blobs.messageRowCount('k'), 2);
  });

  test('the marker survives a reopen of the same database', () async {
    await blobs.write('k', blobOf([1]));
    await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);

    // Same database, fresh in-memory cache: the marker has to be on disk.
    blobs.resetMigratedKeyCache();

    expect(await blobs.isOnMessageRows('k'), isTrue);
  });

  test('an unreadable marker treats every key as unmigrated', () async {
    await blobs.write('k', blobOf([1]));
    await blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob);
    await blobs.write(BlobStore.migratedMarkerKey, 'not json');
    blobs.resetMigratedKeyCache();

    // Safe direction: the blobs are all still there, so re-reading them is
    // correct, where trusting a corrupt marker would hide histories.
    expect(await blobs.isOnMessageRows('k'), isFalse);
  });

  test('migrating one key does not mark or touch another', () async {
    await blobs.write('a', blobOf([1, 2]));
    await blobs.write('b', blobOf([3]));

    await blobs.ensureMessageRowsMigrated('a', rowsFromTestBlob);

    expect(await blobs.isOnMessageRows('b'), isFalse);
    expect(await blobs.messageRowCount('b'), 0);
    expect(await blobs.read('b'), blobOf([3]));
  });

  test('concurrent calls on one key import it exactly once', () async {
    await blobs.write('k', blobOf([1, 2, 3]));

    final results = await Future.wait([
      blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob),
      blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob),
      blobs.ensureMessageRowsMigrated('k', rowsFromTestBlob),
    ]);

    expect(results, everyElement(isTrue));
    expect(await blobs.messageRowCount('k'), 3);
  });
}

/// Stands in for a store's real decoder. Top-level so `compute` can send it.
List<MessageRowInput> rowsFromTestBlob(String blobJson) {
  return (jsonDecode(blobJson) as List<dynamic>)
      .map((e) => e as Map<String, dynamic>)
      .map(
        (m) => MessageRowInput(
          mergeKey: 'id:${m['messageId']}',
          timestampMs: m['timestamp'] as int,
          payload: jsonEncode(m),
        ),
      )
      .toList();
}

List<MessageRowInput> _alwaysThrows(String blobJson) =>
    throw StateError('decoder blew up');

/// Silently loses the last record, which is exactly what the readback gate is
/// there to catch.
List<MessageRowInput> _dropsOneRecord(String blobJson) {
  final all = rowsFromTestBlob(blobJson);
  return all.sublist(0, all.length - 1);
}
