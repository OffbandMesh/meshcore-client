import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/contact_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #673: contacts the app could not read must never be replaced by a save.
/// A decode failure used to return an empty list silently, and the next save
/// wrote whatever was in memory over the stored contacts.
Contact _contact(int keyByte, String name) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, keyByte)),
  name: name,
  type: 1,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

void main() {
  const radioKey = 'd549bbfbd003e580';
  late OffbandDatabase db;
  late BlobStore blobs;
  late ContactStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    blobs = BlobStore(db);
    BlobStore.overrideForTest(blobs);
    store = ContactStore()..setPublicKeyHex = radioKey;
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  test('a readable store round-trips and saves normally', () async {
    await store.saveContacts([_contact(0x11, 'Alpha')]);
    final loaded = await store.loadContacts();

    expect(loaded.map((c) => c.name), ['Alpha']);
    expect(store.lastLoadFailed, isFalse);
  });

  group('an unreadable store', () {
    const corrupt = '[{"publicKey": 12345, "name": "Alpha"';

    setUp(() => blobs.write(store.keyFor, corrupt));

    test('loads as empty but reports the failure', () async {
      expect(await store.loadContacts(), isEmpty);
      expect(store.lastLoadFailed, isTrue);
    });

    test('keeps the raw value aside, untouched', () async {
      await store.loadContacts();

      final aside = (await blobs.keysWithPrefix(
        '${store.keyFor}.unreadable-',
      )).single;
      expect(await blobs.read(aside), corrupt);
    });

    test('refuses a save that would replace it', () async {
      await store.loadContacts();
      await store.saveContacts([_contact(0x22, 'Bravo')]);

      expect(await blobs.read(store.keyFor), corrupt);
    });

    test('saving resumes once a load succeeds again', () async {
      await store.loadContacts();
      await blobs.write(store.keyFor, '[]');
      await store.loadContacts();
      await store.saveContacts([_contact(0x22, 'Bravo')]);

      expect(store.lastLoadFailed, isFalse);
      expect((await store.loadContacts()).map((c) => c.name), ['Bravo']);
    });

    test('does not block saves for a different radio', () async {
      await store.loadContacts();
      store.setPublicKeyHex = 'aa2dccf401e5aaaa';
      await store.saveContacts([_contact(0x33, 'Charlie')]);

      expect((await store.loadContacts()).map((c) => c.name), ['Charlie']);
    });
  });
}
