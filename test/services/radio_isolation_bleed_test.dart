import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/delivery_observation.dart';
import 'package:meshcore_open/models/path_history.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/timeout_prediction_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #937 B2 and B3: the two bleeds, now isolated.
///
/// These were written in Epic A (#936) asserting the BUG, so Epic B had
/// something concrete to invert rather than a prose description. This is that
/// inversion: every expectation that previously demanded the bleed now demands
/// isolation, and the before/after is in the git history of this one file.
///
/// Still against the REAL `StorageService` rather than a fake, because the
/// defect was in the key and a fake would have hidden it.
void main() {
  late OffbandDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    await db.close();
    BlobStore.clearTestOverride();
  });

  PathRecord record(int hops, int ms) => PathRecord(
    hopCount: hops,
    tripTimeMs: ms,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    wasFloodDiscovery: false,
    pathBytes: const [1, 2, 3],
    successCount: 1,
    failureCount: 0,
  );

  StorageService radio(String key) =>
      StorageService()..setPublicKeyHex = key * 20;

  ContactPathHistory history(String contact, int hops, int ms) =>
      ContactPathHistory(
        contactPubKeyHex: contact,
        recentPaths: [record(hops, ms)],
      );

  group('#854 path history is per radio', () {
    test('the key carries the radio, not just the contact', () async {
      await radio('a').savePathHistory('cafebabe', history('cafebabe', 2, 500));

      final keys = await BlobStore.instance.keysWithPrefix('path_history_');

      expect(keys.length, 1);
      expect(
        keys.single,
        'path_history_aaaaaaaaaacafebabe',
        reason:
            'prefix + radio + contact. Before #854 this was '
            'path_history_cafebabe, with no radio in it',
      );
    });

    test('a route learned by radio A is NOT served to radio B', () async {
      await radio(
        'a',
      ).savePathHistory('cafebabe', history('cafebabe', 7, 9000));

      final seenByB = await radio('b').loadPathHistory('cafebabe');

      expect(
        seenByB,
        isNull,
        reason:
            'the 7-hop route radio A measured must not reach radio B. '
            'This asserted hopCount == 7 before Epic B',
      );
    });

    test('each radio keeps its own route to the same contact', () async {
      await radio('a').savePathHistory('cafebabe', history('cafebabe', 2, 400));
      await radio(
        'b',
      ).savePathHistory('cafebabe', history('cafebabe', 7, 9000));

      expect(
        (await radio(
          'a',
        ).loadPathHistory('cafebabe'))!.recentPaths.single.hopCount,
        2,
      );
      expect(
        (await radio(
          'b',
        ).loadPathHistory('cafebabe'))!.recentPaths.single.hopCount,
        7,
      );
    });

    test('an unset radio key loads nothing and writes nothing', () async {
      final unset = StorageService();

      await unset.savePathHistory('cafebabe', history('cafebabe', 2, 400));

      expect(await unset.loadPathHistory('cafebabe'), isNull);
      expect(
        await BlobStore.instance.keysWithPrefix('path_history_'),
        isEmpty,
        reason:
            'the #754 precedent: with no radio connected it must not '
            'write an unscoped key that a later radio could pick up',
      );
    });

    test('clearing one radio does not touch another', () async {
      await radio('a').savePathHistory('cafebabe', history('cafebabe', 2, 400));
      await radio(
        'b',
      ).savePathHistory('cafebabe', history('cafebabe', 7, 9000));

      await radio('a').clearAllPathHistories();

      expect(await radio('a').loadPathHistory('cafebabe'), isNull);
      expect(
        await radio('b').loadPathHistory('cafebabe'),
        isNotNull,
        reason:
            'clearAllPathHistories was global before #854 and would have '
            'taken radio B\'s routes with it',
      );
    });
  });

  group('#856 delivery observations are per radio', () {
    DeliveryObservation obs(int ms, int hops) => DeliveryObservation(
      contactKey: 'cafebabe',
      pathLength: hops,
      messageBytes: 100,
      secondsSinceLastRx: 10,
      isFlood: false,
      deliveryMs: ms,
      timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    test('the key carries the radio', () async {
      await radio('a').saveDeliveryObservations([obs(2500, 3)]);

      final keys = PrefsManager.instance
          .getKeys()
          .where((k) => k.contains('delivery_observations'))
          .toList();

      expect(keys.length, 1);
      expect(
        keys.single.endsWith('delivery_observations${'a' * 10}'),
        isTrue,
        reason: 'before #856 this was the bare key, shared by every radio',
      );
    });

    test(
      'one radio\'s RF timing does NOT reach another radio\'s model',
      () async {
        // A repeater's slow 45-second delivery.
        await radio('a').saveDeliveryObservations([obs(45000, 7)]);

        final otherRadio = TimeoutPredictionService(radio('b'));
        await otherRadio.initialize();

        expect(
          otherRadio.observationCount,
          0,
          reason:
              'radio B has sent nothing, so it must start with no training '
              'data. This asserted 1 before Epic B',
        );
      },
    );

    test('each radio trains on its own observations', () async {
      await radio('a').saveDeliveryObservations([obs(45000, 7)]);
      await radio('b').saveDeliveryObservations([obs(800, 1), obs(900, 1)]);

      final a = TimeoutPredictionService(radio('a'));
      final b = TimeoutPredictionService(radio('b'));
      await a.initialize();
      await b.initialize();

      expect(a.observationCount, 1);
      expect(b.observationCount, 2);
    });
  });

  group('legacy purges (plan decision 1: delete, do not orphan)', () {
    test(
      'untagged path-history keys are removed, scoped ones are not',
      () async {
        // Pre-#854 keys live in PREFS; the new scheme writes to drift, so the
        // two cannot be confused and no shape heuristic is needed.
        SharedPreferences.setMockInitialValues({
          'flutter.path_history_aaaa': '{}',
          'flutter.path_history_bbbb': '{}',
          'flutter.unrelated_setting': 'keep me',
        });
        PrefsManager.reset();
        await PrefsManager.initialize();
        final storage = radio('a');
        await storage.savePathHistory('cafebabe', history('cafebabe', 2, 400));

        final removed = await storage.purgeLegacyPathHistory(chunkSize: 1);

        expect(removed, 2);
        expect(
          PrefsManager.instance.getKeys().where(
            (k) => k.contains('path_history_'),
          ),
          isEmpty,
        );
        expect(
          PrefsManager.instance.getString('unrelated_setting'),
          'keep me',
          reason: 'the purge must touch only its own prefix',
        );
        expect(
          await storage.loadPathHistory('cafebabe'),
          isNotNull,
          reason: 'the drift-side scoped history survives the prefs purge',
        );
      },
    );

    test('purging twice is a no-op, not an error', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.path_history_aaaa': '{}',
      });
      PrefsManager.reset();
      await PrefsManager.initialize();
      final storage = radio('a');

      expect(await storage.purgeLegacyPathHistory(), 1);
      expect(
        await storage.purgeLegacyPathHistory(),
        0,
        reason:
            'it runs on every connect, so it has to be idempotent and '
            'do no writes when there is nothing left',
      );
    });

    test(
      'the global observation list is removed, the scoped one is not',
      () async {
        SharedPreferences.setMockInitialValues({
          'flutter.delivery_observations': '[]',
        });
        PrefsManager.reset();
        await PrefsManager.initialize();
        final storage = radio('a');
        await storage.saveDeliveryObservations([
          DeliveryObservation(
            contactKey: 'cafebabe',
            pathLength: 1,
            messageBytes: 10,
            secondsSinceLastRx: 1,
            isFlood: false,
            deliveryMs: 100,
            timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          ),
        ]);

        expect(await storage.purgeLegacyDeliveryObservations(), isTrue);

        expect(
          PrefsManager.instance.containsKey('delivery_observations'),
          isFalse,
        );
        expect(
          (await storage.loadDeliveryObservations()).length,
          1,
          reason: 'this radio\'s own observations are not collateral',
        );
        expect(
          await storage.purgeLegacyDeliveryObservations(),
          isFalse,
          reason: 'idempotent',
        );
      },
    );
  });
}
