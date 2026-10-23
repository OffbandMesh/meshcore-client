import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/services/stale_history_sweep.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/message_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Epic A of #962, task A1: the diagnosis as failing tests, before anything is
/// built.
///
/// The three reds assert the behaviour the Feature is for and have no
/// implementation yet. The fourth is a control: it asserts SQLite's actual
/// behaviour, passes today, and must keep passing, because it is the whole
/// reason a `VACUUM` step exists at all.
void main() {
  late OffbandDatabase db;
  late BlobStore blobs;

  const key = 'channel_messages_aaaaaaaaaapsk_deadbeef';

  /// A history blob big enough to span many SQLite pages, so page counts move
  /// measurably when it is deleted and the file is rebuilt.
  ///
  /// Built with the store's OWN encoder, deliberately. A hand-rolled JSON
  /// fixture was the first version of this and it did not satisfy the real
  /// parser, which requires `senderName`, `isOutgoing` and `status`. The sweep
  /// then correctly refused the key as unverifiable, and the test looked like
  /// a sweep bug. Using the production encoder means the fixture cannot drift
  /// from what the production converter accepts.
  String bigBlobWith(int count) => ChannelMessageStore.encodeHistoryForTest(
    List.generate(
      count,
      (i) => ChannelMessage(
        senderName: 'sender',
        text: 'message $i ${'x' * 200}',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i),
        isOutgoing: false,
        channelIndex: 0,
        messageId: 'm$i',
      ),
    ),
  );

  /// The real converter, so migration and the sweep's re-verify agree.
  final toRows = channelHistoryToRows;

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

  group('A1 · the diagnosis, red until Epic A is built', () {
    test('migrating a key records WHEN it migrated', () async {
      await blobs.write(key, bigBlobWith(50));
      expect(await blobs.ensureMessageRowsMigrated(key, toRows), isTrue);

      // Today the marker is a flat array of keys with no timestamps, so there
      // is nothing to age a key against.
      expect(
        await blobs.messageRowsMigratedAt(key),
        isNotNull,
        reason: 'without a timestamp the sweep cannot know what is stale',
      );
    });

    test('a key migrated 31 days ago loses its blob to the sweep', () async {
      await blobs.write(key, bigBlobWith(50));
      await blobs.ensureMessageRowsMigrated(key, toRows);
      await blobs.setMessageRowsMigratedAtForTest(
        key,
        DateTime.now().subtract(const Duration(days: 31)),
      );

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, [key]);
      expect(outcome.refused, isEmpty);
      expect(
        await blobs.read(key),
        isNull,
        reason: 'the stale snapshot is the thing this Feature reclaims',
      );
      // The history itself must survive: rows are the source of truth.
      expect(await blobs.messageRowCount(key), 50);
    });

    test('a sweep that deleted something shrinks the database', () async {
      await blobs.write(key, bigBlobWith(400));
      await blobs.ensureMessageRowsMigrated(key, toRows);
      await blobs.setMessageRowsMigratedAtForTest(
        key,
        DateTime.now().subtract(const Duration(days: 31)),
      );

      final before = await blobs.databaseSizeBytes();
      final outcome = await StaleHistorySweep(blobs).run();
      final after = await blobs.databaseSizeBytes();

      expect(outcome.cleared, isNotEmpty);
      expect(
        after,
        lessThan(before),
        reason:
            'a sweep without VACUUM reclaims nothing the user can see, which '
            'is the measured finding this step exists for',
      );
      expect(outcome.bytesBefore, before);
      expect(outcome.bytesAfter, after);
    });
  });

  group('A1 · the control: why a VACUUM step exists', () {
    test('DELETE alone does not shrink the database', () async {
      // Measured on the owner's real database: 74,350,592 bytes before
      // deleting all 40 migrated blobs and 74,350,592 after. This pins that
      // behaviour in a test so nobody "simplifies" the VACUUM away.
      await blobs.write(key, bigBlobWith(400));
      final before = await blobs.databaseSizeBytes();

      await blobs.delete(key);
      final afterDelete = await blobs.databaseSizeBytes();

      expect(
        afterDelete,
        before,
        reason: 'SQLite frees pages for reuse; it does not return them',
      );

      await blobs.vacuum();
      expect(
        await blobs.databaseSizeBytes(),
        lessThan(before),
        reason: 'VACUUM is what actually returns the space',
      );
    });
  });

  /// Migrates [k] and backdates its migration by [days].
  Future<void> migratedDaysAgo(String k, int days, {int messages = 20}) async {
    await blobs.write(k, bigBlobWith(messages));
    expect(await blobs.ensureMessageRowsMigrated(k, toRows), isTrue);
    await blobs.setMessageRowsMigratedAtForTest(
      k,
      DateTime.now().subtract(Duration(days: days)),
    );
  }

  group('what the sweep refuses to touch', () {
    test(
      'a key with ONE blob record missing from rows keeps its blob',
      () async {
        await migratedDaysAgo(key, 31);
        // Remove one row so the blob is no longer fully represented. The blob is
        // now the only copy of that message, which is exactly when deleting it
        // would be data loss.
        final victim = (await blobs.messageMergeKeys(key)).first;
        await blobs.deleteMessageRow(key, victim);

        final outcome = await StaleHistorySweep(blobs).run();

        expect(outcome.refused, [key]);
        expect(outcome.cleared, isEmpty);
        expect(await blobs.read(key), isNotNull);
      },
    );

    test('the same key IS cleared once its rows are complete again', () async {
      // The negative half: this proves the refusal above discriminates rather
      // than the sweep simply never deleting anything.
      await migratedDaysAgo(key, 31);
      final victim = (await blobs.messageMergeKeys(key)).first;
      await blobs.deleteMessageRow(key, victim);
      expect((await StaleHistorySweep(blobs).run()).refused, [key]);

      // Put it back, verbatim, and sweep again.
      final stillThere = await blobs.read(key);
      await blobs.upsertMessageRows(key, toRows(stillThere!));
      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, [key]);
      expect(await blobs.read(key), isNull);
    });

    test('an undecodable blob is refused, not treated as empty', () async {
      await migratedDaysAgo(key, 31);
      await blobs.write(key, 'this is not json');

      final outcome = await StaleHistorySweep(blobs).run();

      expect(
        outcome.refused,
        [key],
        reason:
            'unverifiable and verified-empty must not collapse into the same '
            'answer: that is how the only copy of an unreadable history gets '
            'deleted',
      );
      expect(await blobs.read(key), 'this is not json');
    });

    test('a key inside the window keeps its blob, tested at 29 days', () async {
      await migratedDaysAgo(key, 29);

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, isEmpty);
      expect(await blobs.read(key), isNotNull);
    });

    test('30 days exactly is eligible, so the boundary is pinned', () async {
      await migratedDaysAgo(key, 30);
      expect((await StaleHistorySweep(blobs).run()).cleared, [key]);
    });

    test('a migrated key with no timestamp is stamped, not deleted', () async {
      await blobs.write(key, bigBlobWith(20));
      await blobs.ensureMessageRowsMigrated(key, toRows);
      // Simulate an install that migrated before #962: marked, never stamped.
      await blobs.write(BlobStore.migratedAtKey, '{}');
      blobs.resetMigratedKeyCache();

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, isEmpty);
      expect(await blobs.read(key), isNotNull);
      expect(
        await blobs.messageRowsMigratedAt(key),
        isNotNull,
        reason: 'it must start its window now, not be deleted on sight',
      );
    });

    test('an unmigrated history key keeps its blob', () async {
      await blobs.write(key, bigBlobWith(20));
      // Never migrated: the blob is authoritative.
      expect(await blobs.isOnMessageRows(key), isFalse);

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, isEmpty);
      expect(await blobs.read(key), isNotNull);
    });

    test('non-history keys are never candidates, by name', () async {
      // The blob IS the storage for these: there is no row equivalent, so a
      // sweep that considered them would delete the only copy.
      const others = [
        'contacts',
        'contactsaaaaaaaaaa',
        'discovered_contacts',
        'discovered_contactsaaaaaaaaaa',
        'path_history_aaaaaaaaaacafebabe',
      ];
      for (final k in others) {
        await blobs.write(k, '[{"name":"keep me"}]');
        expect(
          StaleHistorySweep.isHistoryKey(k),
          isFalse,
          reason: '$k must never be considered a history key',
        );
      }
      await migratedDaysAgo(key, 31);

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, [key]);
      for (final k in others) {
        expect(await blobs.read(k), '[{"name":"keep me"}]', reason: k);
      }
    });
  });

  group('a direct-message key sweeps too', () {
    test('messages_ uses the DM converter and is cleared', () async {
      const dmKey = 'messages_aaaaaaaaaacafebabe';
      final history = MessageStore.encodeHistoryForTest([
        Message(
          senderKey: Uint8List.fromList(const [1, 2, 3, 4]),
          text: 'hello',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          isOutgoing: false,
          messageId: 'dm-1',
        ),
      ]);
      await blobs.write(dmKey, history);
      expect(
        await blobs.ensureMessageRowsMigrated(dmKey, dmHistoryToRows),
        isTrue,
      );
      await blobs.setMessageRowsMigratedAtForTest(
        dmKey,
        DateTime.now().subtract(const Duration(days: 31)),
      );

      final outcome = await StaleHistorySweep(blobs).run();

      expect(outcome.cleared, [dmKey]);
      expect(await blobs.read(dmKey), isNull);
      expect(await blobs.messagePayloads(dmKey), hasLength(1));
    });

    test('converterFor picks by shape', () {
      expect(
        StaleHistorySweep.converterFor('channel_messages_x'),
        same(channelHistoryToRows),
      );
      expect(
        StaleHistorySweep.converterFor('messages_x'),
        same(dmHistoryToRows),
      );
    });
  });

  group('VACUUM leaves everything it kept untouched', () {
    test('every kept blob is byte-identical and rows are unchanged', () async {
      // The owner's question, as a test. Measured on his real database: 291
      // kept keys including all 98 unmigrated history blobs came through
      // hash-identical. This is the same assertion in miniature.
      await migratedDaysAgo(key, 31, messages: 200);
      const unmigrated = 'channel_messages_bbbbbbbbbbpsk_feedface';
      await blobs.write(unmigrated, bigBlobWith(50));
      await blobs.write('contacts', '[{"name":"a"}]');
      await blobs.write('path_history_ccccccccccdeadbeef', '{"paths":[]}');

      final before = <String, String>{};
      for (final k in await blobs.keysWithPrefix('')) {
        if (k == key) continue; // the one we expect to go
        before[k] = (await blobs.read(k))!;
      }
      final rowsBefore = await blobs.messageRowCount(key);

      final outcome = await StaleHistorySweep(blobs).run();
      expect(outcome.cleared, [key]);

      for (final entry in before.entries) {
        expect(
          await blobs.read(entry.key),
          entry.value,
          reason: '${entry.key} changed across the sweep and VACUUM',
        );
      }
      expect(
        await blobs.read(unmigrated),
        isNotNull,
        reason: 'the unmigrated history blob is the only copy of its history',
      );
      expect(
        await blobs.messageRowCount(key),
        rowsBefore,
        reason: 'the history itself must survive losing its stale snapshot',
      );
      expect(outcome.bytesReclaimed, greaterThan(0));
    });
  });
}
