import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #920 B1: one row per message. These pin the properties the stores and the
/// migration are about to rely on, in particular that an upsert is scoped to
/// its store key and deduped by merge key exactly as the blob merge was.
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

  MessageRowInput row(int i, {String? text, String? id}) => MessageRowInput(
    mergeKey: 'id:${id ?? 'id$i'}',
    timestampMs: 1000 + i,
    payload: '{"messageId":"${id ?? 'id$i'}","text":"${text ?? 'm$i'}"}',
  );

  test('stores and reads back in timestamp order', () async {
    // Inserted out of order on purpose: ordering must come from SQLite, not
    // from insertion sequence.
    await blobs.upsertMessageRows('k', [row(9), row(2), row(5)]);

    final out = await blobs.messagePayloads('k');

    expect(out, [
      '{"messageId":"id2","text":"m2"}',
      '{"messageId":"id5","text":"m5"}',
      '{"messageId":"id9","text":"m9"}',
    ]);
  });

  test('upsert on the same merge key updates, never duplicates', () async {
    await blobs.upsertMessageRows('k', [row(1, text: 'original')]);
    await blobs.upsertMessageRows('k', [row(1, text: 'edited')]);

    expect(await blobs.messageRowCount('k'), 1);
    expect(await blobs.messagePayloads('k'), [
      '{"messageId":"id1","text":"edited"}',
    ]);
  });

  test('rows are scoped to their store key', () async {
    // The key carries all the per-radio and per-channel scoping (#194, #472),
    // so a leak across keys here would be a history bleed between radios.
    await blobs.upsertMessageRows('radio_a', [row(1), row(2)]);
    await blobs.upsertMessageRows('radio_b', [row(1)]);

    expect(await blobs.messageRowCount('radio_a'), 2);
    expect(await blobs.messageRowCount('radio_b'), 1);
    expect(await blobs.messagePayloads('radio_b'), [
      '{"messageId":"id1","text":"m1"}',
    ]);
  });

  test('the same merge key under two store keys is two messages', () async {
    await blobs.upsertMessageRows('a', [row(1, text: 'in a')]);
    await blobs.upsertMessageRows('b', [row(1, text: 'in b')]);

    expect(await blobs.messagePayloads('a'), [
      '{"messageId":"id1","text":"in a"}',
    ]);
    expect(await blobs.messagePayloads('b'), [
      '{"messageId":"id1","text":"in b"}',
    ]);
  });

  test('limit returns the NEWEST n, still oldest-first', () async {
    await blobs.upsertMessageRows('k', [for (var i = 1; i <= 10; i++) row(i)]);

    final out = await blobs.messagePayloads('k', limit: 3);

    expect(out, [
      '{"messageId":"id8","text":"m8"}',
      '{"messageId":"id9","text":"m9"}',
      '{"messageId":"id10","text":"m10"}',
    ]);
  });

  test('limit with offset pages backwards through history', () async {
    await blobs.upsertMessageRows('k', [for (var i = 1; i <= 10; i++) row(i)]);

    final page2 = await blobs.messagePayloads('k', limit: 3, offset: 3);

    expect(page2, [
      '{"messageId":"id5","text":"m5"}',
      '{"messageId":"id6","text":"m6"}',
      '{"messageId":"id7","text":"m7"}',
    ]);
  });

  test('deleting one row leaves the rest alone', () async {
    await blobs.upsertMessageRows('k', [row(1), row(2), row(3)]);

    await blobs.deleteMessageRow('k', 'id:id2');

    expect(await blobs.messagePayloads('k'), [
      '{"messageId":"id1","text":"m1"}',
      '{"messageId":"id3","text":"m3"}',
    ]);
  });

  test('deleting one row does not touch another store key', () async {
    await blobs.upsertMessageRows('a', [row(1)]);
    await blobs.upsertMessageRows('b', [row(1)]);

    await blobs.deleteMessageRow('a', 'id:id1');

    expect(await blobs.messageRowCount('a'), 0);
    expect(await blobs.messageRowCount('b'), 1);
  });

  test('clearing a key removes only that key', () async {
    await blobs.upsertMessageRows('a', [row(1), row(2)]);
    await blobs.upsertMessageRows('b', [row(1)]);

    await blobs.deleteMessageRows('a');

    expect(await blobs.messageRowCount('a'), 0);
    expect(await blobs.messageRowCount('b'), 1);
  });

  test('messageStoreKeys lists keys that have rows, deduped', () async {
    await blobs.upsertMessageRows('a', [row(1), row(2)]);
    await blobs.upsertMessageRows('b', [row(1)]);

    expect(await blobs.messageStoreKeys(), {'a', 'b'});
  });

  test('an empty upsert is a no-op, not an error', () async {
    await blobs.upsertMessageRows('k', const []);

    expect(await blobs.messageRowCount('k'), 0);
  });

  test('count and payloads are empty for an unknown key', () async {
    expect(await blobs.messageRowCount('never-seen'), 0);
    expect(await blobs.messagePayloads('never-seen'), isEmpty);
  });

  test('message rows and the blob for the same key coexist', () async {
    // The migration is additive: during and after it, the blob is still there
    // and must not be disturbed by anything on the row path (#920).
    await blobs.write('k', '[{"messageId":"old"}]');
    await blobs.upsertMessageRows('k', [row(1)]);

    expect(await blobs.read('k'), '[{"messageId":"old"}]');
    expect(await blobs.messageRowCount('k'), 1);

    await blobs.deleteMessageRows('k');
    expect(
      await blobs.read('k'),
      '[{"messageId":"old"}]',
      reason: 'clearing rows must never touch the retained blob',
    );
  });
}
