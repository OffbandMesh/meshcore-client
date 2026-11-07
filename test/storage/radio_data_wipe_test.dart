import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/factory_reset_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/storage/radio_data_wipe.dart';
import 'package:meshcore_open/storage/scoping_inventory.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #1057: the factory-reset app-data wipe and the reconnect decision.
void main() {
  late OffbandDatabase db;

  const wiped = 'aaaaaaaaaa';
  const other = 'bbbbbbbbbb';

  final perRadio = [
    for (final s in storageSurfaces)
      if (s.verdict == ScopingVerdict.perRadio) s.key,
  ];
  final global = [
    for (final s in storageSurfaces)
      if (s.verdict == ScopingVerdict.globalOnPurpose) s.key,
  ];

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

  /// Every perRadio surface gets a drift key, a prefs key and message rows for
  /// both radios, so the wipe has to tell them apart in every backend.
  Future<void> seed() async {
    final blobs = BlobStore.instance;
    final prefs = PrefsManager.instance;
    for (final radio in [wiped, other]) {
      for (final surface in perRadio) {
        await blobs.write('$surface${radio}_drift', 'v');
        await prefs.setString('$surface${radio}_prefs', 'v');
        await blobs.upsertMessageRows('$surface${radio}_rows', const [
          MessageRowInput(mergeKey: 'm', timestampMs: 1, payload: '{}'),
        ]);
      }
    }
    for (final surface in global) {
      await prefs.setString(surface, 'v');
    }
  }

  Future<Set<String>> allKeys() async => {
    ...await BlobStore.instance.keysWithPrefix(''),
    ...await BlobStore.instance.messageStoreKeys(),
  };

  test('removes every perRadio surface of the reset radio, in every '
      'backend', () async {
    await seed();
    await wipeRadioData(wiped);

    final left = await allKeys();
    for (final surface in perRadio) {
      expect(
        left.where((k) => k.startsWith('$surface$wiped')),
        isEmpty,
        reason: '$surface survived the wipe',
      );
    }
  });

  test('leaves another radio and every global surface alone', () async {
    await seed();
    await wipeRadioData(wiped);

    final left = await allKeys();
    for (final surface in perRadio) {
      for (final suffix in ['_drift', '_prefs', '_rows']) {
        expect(left, contains('$surface$other$suffix'));
      }
    }
    for (final surface in global) {
      expect(PrefsManager.instance.getString(surface), 'v');
    }
  });

  test('refuses anything but a 10-hex prefix, before deleting', () async {
    await seed();
    final before = await allKeys();

    for (final bad in [
      '',
      'aaaaa',
      'AAAAAAAAAA',
      'aaaaaaaaaaa',
      'zzzzzzzzzz',
    ]) {
      await expectLater(wipeRadioData(bad), throwsArgumentError);
    }
    expect(await allKeys(), before);
  });

  group('resolveFactoryReset', () {
    const pending = PendingFactoryReset(
      deviceId: 'dev-1',
      radioPrefix: wiped,
      deleteAppData: true,
    );

    test('new key on the same device with the box ticked wipes', () {
      expect(
        resolveFactoryReset(pending, deviceId: 'dev-1', radioPrefix: other),
        FactoryResetOutcome.wipeAppData,
      );
    });

    test('new key with the box unticked keeps', () {
      const keep = PendingFactoryReset(
        deviceId: 'dev-1',
        radioPrefix: wiped,
        deleteAppData: false,
      );
      expect(
        resolveFactoryReset(keep, deviceId: 'dev-1', radioPrefix: other),
        FactoryResetOutcome.keepAppData,
      );
    });

    test('same key means the radio was not reset', () {
      expect(
        resolveFactoryReset(pending, deviceId: 'dev-1', radioPrefix: wiped),
        FactoryResetOutcome.notReset,
      );
    });

    test('a different device decides nothing', () {
      expect(
        resolveFactoryReset(pending, deviceId: 'dev-2', radioPrefix: other),
        isNull,
      );
    });
  });

  test('the pending record survives a restart and clears', () async {
    final store = FactoryResetStore();
    await store.save(
      const PendingFactoryReset(
        deviceId: 'COM7',
        radioPrefix: wiped,
        deleteAppData: true,
      ),
    );

    final reloaded = FactoryResetStore().load();
    expect(reloaded?.deviceId, 'COM7');
    expect(reloaded?.radioPrefix, wiped);
    expect(reloaded?.deleteAppData, isTrue);

    await store.clear();
    expect(FactoryResetStore().load(), isNull);
  });

  test('an unreadable pending record loads as none', () async {
    await PrefsManager.instance.setString('factory_reset_pending', '{oops');
    expect(FactoryResetStore().load(), isNull);
  });
}
