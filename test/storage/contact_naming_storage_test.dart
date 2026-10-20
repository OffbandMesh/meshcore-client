// Custom Name override for contacts (#750), storage half.
//
// Tests T7, T8, T9, T31 and T32 from the plan of record,
// docs/initiatives/standalone/750-contact-naming/PLAN.md.
//
// T32 is the data-loss guard that the plan correction on #750 added. Persisting
// `contact.name` instead of `contact.receivedName` would write a user's private
// label into the `name` key, and the next load would read it back as what the
// node calls itself. The real name would be gone permanently, with no advert
// able to restore it because the contact would already appear to have it.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/contact_settings_store.dart';
import 'package:meshcore_open/storage/contact_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _radioKey = 'd549bbfbd003e580';
const _contactKey = '00112233445566778899aabbccddeeff';

Contact _contact({required String receivedName, String? customName}) => Contact(
  publicKey: Uint8List.fromList(List<int>.filled(32, 0x22)),
  receivedName: receivedName,
  customName: customName,
  type: 1,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

void main() {
  late OffbandDatabase db;
  late BlobStore blobs;
  late ContactStore store;
  late ContactSettingsStore settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    blobs = BlobStore(db);
    BlobStore.overrideForTest(blobs);
    store = ContactStore()..setPublicKeyHex = _radioKey;
    settings = ContactSettingsStore()..setPublicKeyHex = _radioKey;
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  group('contact_store and the received name (#750)', () {
    test('T7 + a stored contact round-trips its received name', () async {
      await store.saveContacts([_contact(receivedName: 'KQ4EZN-Repeater')]);
      final loaded = await store.loadContacts();

      expect(loaded.single.receivedName, 'KQ4EZN-Repeater');
      expect(loaded.single.name, 'KQ4EZN-Repeater');
    });

    test('T8 - loading never invents a custom name', () async {
      // If the migration populated customName from the stored name, every
      // existing contact would silently become "renamed" and adverts would
      // stop updating any of them. That is the worst failure in this epic and
      // a positive-only suite would never see it.
      await store.saveContacts([_contact(receivedName: 'KQ4EZN-Repeater')]);
      final loaded = await store.loadContacts();

      expect(loaded.single.customName, isNull);
    });

    test(
      'T32 - saving a renamed contact keeps the received name on disk',
      () async {
        // The data-loss guard. `contact.name` would be 'Chuck' here.
        await store.saveContacts([
          _contact(receivedName: 'KQ4EZN-Repeater', customName: 'Chuck'),
        ]);
        final loaded = await store.loadContacts();

        expect(
          loaded.single.receivedName,
          'KQ4EZN-Repeater',
          reason: 'the custom name must not be persisted as the received name',
        );
        expect(
          loaded.single.customName,
          isNull,
          reason:
              'contact_store does not own the custom name; a radio sync '
              'rebuilds this record and would wipe it',
        );
      },
    );

    test(
      'T31 - a legacy row with no name loads as Unknown, not a crash',
      () async {
        // `receivedName` is non-nullable, and the pre-#750 reader had
        // `json['name'] as String? ?? 'Unknown'`. Dropping that fallback during
        // the rename would crash the load for anyone holding such a row.
        await BlobStore.instance.write(
          store.keyFor,
          '[{"publicKey":"${base64OfKey()}","type":1,"pathLength":-1,"lastSeen":0}]',
        );

        final loaded = await store.loadContacts();

        expect(loaded.single.receivedName, 'Unknown');
        expect(loaded.single.name, 'Unknown');
      },
    );
  });

  group('contact_settings_store owns the custom name (#750)', () {
    test('T9 + a custom name round-trips', () async {
      await settings.saveCustomName(_contactKey, 'Chuck');

      expect(await settings.loadCustomName(_contactKey), 'Chuck');
    });

    test(
      'T9b - an unknown contact returns null, not an empty string',
      () async {
        expect(await settings.loadCustomName('ffffffffffffffff'), isNull);
      },
    );

    test('T9c + clearing with null removes it', () async {
      await settings.saveCustomName(_contactKey, 'Chuck');
      await settings.saveCustomName(_contactKey, null);

      expect(await settings.loadCustomName(_contactKey), isNull);
    });

    test(
      'T9d - saving an empty name stores nothing, not an empty string',
      () async {
        // The store is the second enforcement point for "empty counts as unset",
        // so a UI that passes '' cannot leave a contact with a blank name.
        await settings.saveCustomName(_contactKey, 'Chuck');
        await settings.saveCustomName(_contactKey, '');

        expect(await settings.loadCustomName(_contactKey), isNull);
      },
    );

    test('T9e - saving a whitespace-only name stores nothing', () async {
      await settings.saveCustomName(_contactKey, 'Chuck');
      await settings.saveCustomName(_contactKey, '   ');

      expect(await settings.loadCustomName(_contactKey), isNull);
    });

    test('T9f + a custom name with emoji and CJK survives storage', () async {
      const rich = '测试 🧙‍♂️ Chuck';
      await settings.saveCustomName(_contactKey, rich);

      expect(await settings.loadCustomName(_contactKey), rich);
    });
  });
}

/// Base64 of the 32-byte key used by [_contact], for the legacy-row fixture.
String base64OfKey() => 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=';
