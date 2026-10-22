import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #952: the migration's readback gate asserts a superset, not equality.
///
/// Found on the owner's live database while working #943. Four of his store
/// keys held rows whose `merge_key` did not appear in their blob (1, 3, 7 and
/// 5 of them), so the old gate's comparison of TOTALS could never come level
/// again: nothing removes those rows and the frozen blob can never come to
/// contain them. Every attempt refused, forever, and his two largest channels
/// (6,313 and 5,648 messages) were among them, still re-encoding their whole
/// history on every save.
///
/// The invariant that was actually wanted is "no record from the blob is
/// missing from rows". These tests pin that, and that it still catches the
/// short insert the step exists for.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  const key = 'channel_messages_aaaaaaaaaapsk_deadbeef';

  /// A channel history blob. Only `messageId` matters here: both stores' merge
  /// key is `id:<messageId>` whenever it is non-empty.
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

  group('rows the blob does not contain no longer block the migration', () {
    test('one extra row still migrates', () async {
      await blobs.write(key, blobWith(['a', 'b', 'c']));
      // The state the owner's four keys were in. Under the old gate this
      // compared 4 stored rows against 3 blob records and refused.
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
      ]);

      expect(await blobs.ensureMessageRowsMigrated(key, toRows), isTrue);
      expect(await blobs.isOnMessageRows(key), isTrue);
    });

    test('the extra row is kept, not discarded', () async {
      await blobs.write(key, blobWith(['a', 'b', 'c']));
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(
          mergeKey: 'id:newer',
          timestampMs: 2,
          payload: '{"messageId":"newer"}',
        ),
      ]);
      await blobs.ensureMessageRowsMigrated(key, toRows);

      // Accepting the migration must not lose the message that caused the
      // mismatch: it is newer than the blob, not spurious.
      expect(await blobs.messageMergeKeys(key), contains('id:newer'));
      expect(await blobs.messageRowCount(key), 4);
    });

    test('his worst key in miniature: many records, a few extra', () async {
      await blobs.write(key, blobWith(List.generate(60, (i) => 'm$i')));
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(mergeKey: 'id:x1', timestampMs: 9, payload: '{}'),
        MessageRowInput(mergeKey: 'id:x2', timestampMs: 9, payload: '{}'),
        MessageRowInput(mergeKey: 'id:x3', timestampMs: 9, payload: '{}'),
        MessageRowInput(mergeKey: 'id:x4', timestampMs: 9, payload: '{}'),
        MessageRowInput(mergeKey: 'id:x5', timestampMs: 9, payload: '{}'),
      ]);

      expect(await blobs.ensureMessageRowsMigrated(key, toRows), isTrue);
      expect(await blobs.messageRowCount(key), 65);
    });

    test('a key stuck under the old gate recovers on next access', () async {
      // The outcome that matters for his install: no healing migration is
      // needed, the four keys migrate normally once the comparison is right.
      await blobs.write(key, blobWith(['a', 'b', 'c']));
      await blobs.upsertMessageRows(key, const [
        MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
      ]);
      expect(await blobs.isOnMessageRows(key), isFalse);

      expect(await blobs.ensureMessageRowsMigrated(key, toRows), isTrue);
      expect(await blobs.isOnMessageRows(key), isTrue);
    });
  });

  group('the gate can still fail', () {
    test('a short insert is refused and the key stays on the blob', () async {
      // Proving the step still does its job. A store whose insert silently
      // drops a row is exactly what the readback exists to catch, and the
      // superset check must not have traded that away.
      final lossy = _DropsOneRow(db);
      BlobStore.overrideForTest(lossy);
      await lossy.write(key, blobWith(['a', 'b', 'c']));

      expect(
        await lossy.ensureMessageRowsMigrated(key, toRows),
        isFalse,
        reason: 'one of the three blob records never reached a row',
      );
      expect(await lossy.isOnMessageRows(key), isFalse);
    });

    test('a lossy converter is refused before anything is written', () async {
      // The other half of the loop (step 2), unchanged by #952: the blob's
      // element count is measured independently of the converter.
      await blobs.write(key, blobWith(['a', 'b', 'c']));

      expect(
        await blobs.ensureMessageRowsMigrated(key, (json) {
          final all = toRows(json);
          return all.take(all.length - 1).toList();
        }),
        isFalse,
      );
      expect(await blobs.messageRowCount(key), 0);
    });
  });

  test('no message is lost either way: the blob is retained', () async {
    final history = blobWith(['a', 'b', 'c']);
    await blobs.write(key, history);
    await blobs.upsertMessageRows(key, const [
      MessageRowInput(mergeKey: 'id:newer', timestampMs: 2, payload: '{}'),
    ]);
    await blobs.ensureMessageRowsMigrated(key, toRows);

    expect(await blobs.read(key), history);
  });
}

/// A [BlobStore] whose row insert silently drops the first row, standing in
/// for a short or partially failed write.
class _DropsOneRow extends BlobStore {
  _DropsOneRow(super.db);

  @override
  Future<void> upsertMessageRows(
    String storeKey,
    Iterable<MessageRowInput> rows,
  ) => super.upsertMessageRows(storeKey, rows.skip(1));
}
