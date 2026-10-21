import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/delivery_observation.dart';
import 'package:meshcore_open/models/path_history.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/services/timeout_prediction_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #936 A2: the two remaining bleeds, reproduced against the real store.
///
/// **These assert the BUG on purpose.** They are characterization tests: they
/// pin exactly what bleeds today so Epic B (#937) has something concrete to
/// invert, and so the bleed cannot be quietly half-fixed. Each one names the
/// issue it characterizes and says what Epic B replaces it with.
///
/// Why characterization rather than genuinely-failing tests, which is what the
/// plan's A2 asked for: a red test cannot merge, and Epic A's PR has to land
/// before Epic B starts. These demonstrate the bleed just as concretely and go
/// red the moment it stops, which is the property that matters.
///
/// They use the REAL `StorageService` against real prefs, not the
/// `FakeStorageService` the existing path-history tests use, because the defect
/// is in the KEY rather than in the service logic. A fake would hide it.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
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

  group('#854 path history bleeds between radios', () {
    test('BUG: the stored key carries no radio, only the contact '
        '(Epic B scopes it)', () async {
      final storage = StorageService();
      await storage.savePathHistory(
        'cafebabe',
        ContactPathHistory(
          contactPubKeyHex: 'cafebabe',
          recentPaths: [record(2, 500)],
        ),
      );

      final keys = PrefsManager.instance
          .getKeys()
          .where((k) => k.contains('path_history_'))
          .toList();

      expect(keys.length, 1, reason: 'one contact, one key');
      expect(
        keys.single,
        contains('path_history_cafebabe'),
        reason:
            'the key is prefix + contact. There is no radio in it, '
            'which IS the bug: any radio that shares this contact reads '
            'and overwrites the same route',
      );
    });

    test('BUG: a route learned under radio A is served to radio B '
        '(Epic B isolates them)', () async {
      // Nothing here distinguishes the radios, because the store offers no
      // way to: `savePathHistory` takes a contact and nothing else. That is
      // the defect, demonstrated rather than described. Two StorageService
      // instances standing in for two connected radios share one row.
      final radioA = StorageService();
      final radioB = StorageService();

      await radioA.savePathHistory(
        'cafebabe',
        ContactPathHistory(
          contactPubKeyHex: 'cafebabe',
          recentPaths: [record(7, 9000)],
        ),
      );

      final seenByB = await radioB.loadPathHistory('cafebabe');

      expect(
        seenByB?.recentPaths.single.hopCount,
        7,
        reason:
            'radio B sees a 7-hop route it never learned. A route '
            'measured by a 1 W handheld is applied to a repeater. After '
            'Epic B this must be null for radio B',
      );
    });
  });

  group('#856 delivery observations bleed between radios', () {
    test('BUG: observations live under one global key '
        '(Epic B scopes it)', () async {
      final storage = StorageService();
      await storage.saveDeliveryObservations([
        DeliveryObservation(
          contactKey: 'cafebabe',
          pathLength: 3,
          messageBytes: 100,
          secondsSinceLastRx: 10,
          isFlood: false,
          deliveryMs: 2500,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      ]);

      final keys = PrefsManager.instance
          .getKeys()
          .where((k) => k.contains('delivery_observations'))
          .toList();

      expect(keys.length, 1);
      expect(
        keys.single.endsWith('delivery_observations'),
        isTrue,
        reason:
            'no radio component. Every radio trains on, and pollutes, '
            'the same ACK-timeout model',
      );
    });

    test('BUG: one radio\'s RF timing reaches another radio\'s model '
        '(Epic B isolates them)', () async {
      // A slow, many-hop repeater observation, then a fresh service standing
      // in for a different radio. It inherits the other radio's timing.
      await StorageService().saveDeliveryObservations([
        DeliveryObservation(
          contactKey: 'cafebabe',
          pathLength: 7,
          messageBytes: 100,
          secondsSinceLastRx: 10,
          isFlood: false,
          deliveryMs: 45000,
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      ]);

      final otherRadio = TimeoutPredictionService(StorageService());
      await otherRadio.initialize();

      expect(
        otherRadio.observationCount,
        1,
        reason:
            'this radio has sent nothing, yet it starts with another '
            'radio\'s 45-second observation in its training data. After '
            'Epic B this must be 0',
      );
    });
  });

  group('#855 pending messages', () {
    test('the API round-trips but nothing in the app calls it '
        '(Epic B deletes it)', () async {
      // Kept deliberately small: the finding is that this API has no
      // callers in lib/ or test/, which a unit test cannot assert. It is
      // recorded in scoping_inventory.dart and proved by grep. This test
      // only pins that the thing being deleted currently works, so the
      // deletion is removal of dead code rather than of a live feature.
      final storage = StorageService();
      await storage.savePendingMessages({'a': 'b'});

      expect(await storage.loadPendingMessages(), {'a': 'b'});
    });
  });
}
