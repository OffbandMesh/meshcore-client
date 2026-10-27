import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/contact_discovery_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #754: discovered contacts are what THIS radio heard, so they must be scoped
// per radio like every other store, not shared across radios on one host.
void main() {
  // Full-length keys; the store scopes on the first 10 hex, like production.
  final keyA = 'aa' * 32;
  final keyB = 'bb' * 32;

  late OffbandDatabase db;

  Contact node(int keyByte, String name) => Contact(
    publicKey: Uint8List.fromList(List<int>.filled(32, keyByte)),
    receivedName: name,
    type: 1,
    pathLength: -1,
    path: Uint8List(0),
    lastSeen: DateTime.utc(2026, 1, 1),
  );

  ContactDiscoveryStore store(String deviceKey) {
    final s = ContactDiscoveryStore();
    s.setPublicKeyHex = deviceKey;
    return s;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  test(
    'radio A discoveries are not visible while radio B is connected',
    () async {
      await store(
        keyA,
      ).saveContacts([node(0x11, 'Alpha'), node(0x22, 'Bravo')]);

      expect((await store(keyA).loadContacts()).map((c) => c.name).toSet(), {
        'Alpha',
        'Bravo',
      });
      expect(await store(keyB).loadContacts(), isEmpty);
    },
  );

  test(
    'an unset device key loads nothing, never the legacy shared blob',
    () async {
      await store(keyA).saveContacts([node(0x11, 'Alpha')]);

      final unscoped = ContactDiscoveryStore(); // no radio connected
      expect(await unscoped.loadContacts(), isEmpty);
      // A save with no radio connected must not write a shared blob either.
      await unscoped.saveContacts([node(0x99, 'Ghost')]);
      expect(await store(keyB).loadContacts(), isEmpty);
    },
  );

  test('each radio keeps its own discovery list across a switch', () async {
    await store(keyA).saveContacts([node(0x11, 'Alpha')]);
    await store(keyB).saveContacts([node(0x22, 'Bravo')]);

    expect((await store(keyA).loadContacts()).single.name, 'Alpha');
    expect((await store(keyB).loadContacts()).single.name, 'Bravo');
  });
}
