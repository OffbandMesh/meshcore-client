import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Found while working #943, on the owner's live database.
///
/// Four of his store keys hold rows but are NOT in the migrated marker, so
/// they still read and write through the blob. Each one has rows whose
/// `merge_key` does not appear in its blob (1, 3, 7 and 5 of them). The
/// readback gate in `ensureMessageRowsMigrated` compares the key's TOTAL row
/// count against the number of distinct records in the blob, so those extra
/// rows make the two numbers differ and the migration is refused.
///
/// The gate's own log line calls the leftover rows "harmless because the key
/// is not marked migrated". These tests check that claim. It does not hold:
/// nothing ever removes the extra rows and the blob can never come to contain
/// them, so the comparison fails identically on every future attempt and the
/// key is stuck on the blob path for good.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  const key = 'channel_messages_aaaaaaaaaapsk_deadbeef';

  /// Two records, as a channel history blob. Only `messageId` matters here:
  /// both stores' merge key is `id:<messageId>` whenever it is non-empty.
  String blobWith(List<String> ids) =>
      '[${ids.map((id) => '{"messageId":"$id","text":"t-$id","timestamp":1}').join(',')}]';

  List<MessageRowInput> toRows(String json) {
    final ids = RegExp(
      r'"messageId":"([^"]+)"',
    ).allMatches(json).map((m) => m.group(1)!).toList();
    return ids
        .map(
          (id) => MessageRowInput(
            mergeKey: 'id:$id',
            timestampMs: 1,
            payload: '{"messageId":"$id"}',
          ),
        )
        .toList();
  }

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

  test('a clean key migrates, so the fixture itself is sound', () async {
    await blobs.write(key, blobWith(['a', 'b', 'c']));

    expect(await blobs.ensureMessageRowsMigrated(key, toRows), isTrue);
    expect(await blobs.isOnMessageRows(key), isTrue);
    expect(await blobs.messageRowCount(key), 3);
  });

  test('one row the blob does not contain is enough to refuse', () async {
    await blobs.write(key, blobWith(['a', 'b', 'c']));
    // The state the owner's four keys are in: a row for a message that is not
    // in the blob. On his biggest channel this is 5 rows against 6,308.
    await blobs.upsertMessageRows(key, const [
      MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
    ]);

    expect(
      await blobs.ensureMessageRowsMigrated(key, toRows),
      isFalse,
      reason: 'the gate compares 4 stored rows against 3 blob records',
    );
    expect(await blobs.isOnMessageRows(key), isFalse);
  });

  test('and it refuses again, every time, for good', () async {
    await blobs.write(key, blobWith(['a', 'b', 'c']));
    await blobs.upsertMessageRows(key, const [
      MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
    ]);

    for (var attempt = 1; attempt <= 3; attempt++) {
      expect(
        await blobs.ensureMessageRowsMigrated(key, toRows),
        isFalse,
        reason: 'attempt $attempt refused',
      );
    }

    // Nothing cleaned up the extra row, which is why the next attempt fails
    // the same way. This is the trap: the key cannot recover on its own.
    expect(await blobs.messageRowCount(key), 4);
    expect(await blobs.isOnMessageRows(key), isFalse);
  });

  test('a growing blob does not rescue it either', () async {
    await blobs.write(key, blobWith(['a', 'b', 'c']));
    await blobs.upsertMessageRows(key, const [
      MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
    ]);
    expect(await blobs.ensureMessageRowsMigrated(key, toRows), isFalse);

    // The key stays on the blob path, so new traffic lands in the blob. That
    // is the only thing about this key that changes over time, and it moves
    // the two numbers further apart rather than together.
    await blobs.write(key, blobWith(['a', 'b', 'c', 'd', 'e']));

    expect(
      await blobs.ensureMessageRowsMigrated(key, toRows),
      isFalse,
      reason: '6 rows against 5 blob records: still unequal',
    );
  });

  test(
    'no message is actually lost, which is why this is not data loss',
    () async {
      // Worth pinning: the blob remains complete and authoritative for a refused
      // key, so the cost here is the save path, not history.
      final history = blobWith(['a', 'b', 'c']);
      await blobs.write(key, history);
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
      ]);
      await blobs.ensureMessageRowsMigrated(key, toRows);

      expect(await blobs.read(key), history);
    },
  );
}
