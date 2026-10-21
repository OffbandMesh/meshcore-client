// Custom Name override for contacts (#750), task 750.3: the live lifecycle.
//
// The custom name is stored in contact_settings_store keyed by pubkey, so it
// has to be reattached to the live Contact objects. Two paths drop it if the
// wiring is missing, and both are silent:
//
//   1. cache hydrate rebuilds every Contact from contact_store, which does not
//      hold the custom name on purpose (a radio sync would wipe it there);
//   2. radio contact-sync replaces an existing Contact with one built from the
//      device frame, where no custom name exists.
//
// Tests T15 to T22 from the plan, plus T34 and T35 for the two paths above.
//
// T15 to T22 guard behaviour that 750.1 already delivered, so they pass on
// arrival and are regression guards rather than watched failures. T34 and T35
// are the watched ones for this task.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/storage/contact_settings_store.dart';
import 'package:meshcore_open/storage/contact_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _radioKey = 'd549bbfbd003e580';
const _received = 'KQ4EZN-Repeater';
const _custom = 'Chuck';

Uint8List _key(int b) => Uint8List.fromList(List<int>.filled(32, b));

Contact _contact({
  int keyByte = 0x44,
  String receivedName = _received,
  String? customName,
}) => Contact(
  publicKey: _key(keyByte),
  receivedName: receivedName,
  customName: customName,
  type: advTypeChat,
  pathLength: -1,
  path: Uint8List(0),
  lastSeen: DateTime.utc(2026, 7, 1),
);

void main() {
  late OffbandDatabase db;
  late MeshCoreConnector connector;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));
    connector = MeshCoreConnector();
    connector.contactsForTest.clear();
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  group('a custom name survives the paths that rebuild a Contact (#750)', () {
    test('T35 - cache hydrate restores the custom name', () async {
      // contact_store deliberately does not persist customName, so without
      // this wiring a restart silently loses every rename the user made.
      final store = ContactStore()..setPublicKeyHex = _radioKey;
      final settings = ContactSettingsStore()..setPublicKeyHex = _radioKey;
      await store.saveContacts([_contact()]);
      await settings.saveCustomName(_contact().publicKeyHex, _custom);

      await connector.loadContactCacheForTest(_radioKey);

      final loaded = connector.contactsForTest.single;
      expect(loaded.customName, _custom);
      expect(loaded.name, _custom);
      expect(
        loaded.receivedName,
        _received,
        reason: 'the received name must survive alongside it',
      );
    });

    test('T35b + a contact with no custom name hydrates unchanged', () async {
      final store = ContactStore()..setPublicKeyHex = _radioKey;
      await store.saveContacts([_contact()]);

      await connector.loadContactCacheForTest(_radioKey);

      final loaded = connector.contactsForTest.single;
      expect(loaded.customName, isNull);
      expect(loaded.name, _received);
    });

    test(
      'T34 + setting a custom name persists it and shows immediately',
      () async {
        final settings = ContactSettingsStore()..setPublicKeyHex = _radioKey;
        connector.setContactSettingsKeyForTest(_radioKey);
        connector.contactsForTest.add(_contact());

        await connector.setContactCustomName(_contact().publicKeyHex, _custom);

        expect(connector.contactsForTest.single.name, _custom);
        expect(
          await settings.loadCustomName(_contact().publicKeyHex),
          _custom,
          reason: 'it must reach storage, not just memory',
        );
      },
    );

    test(
      'T34b + clearing a custom name reverts to the received name',
      () async {
        final settings = ContactSettingsStore()..setPublicKeyHex = _radioKey;
        connector.setContactSettingsKeyForTest(_radioKey);
        connector.contactsForTest.add(_contact(customName: _custom));

        await connector.setContactCustomName(_contact().publicKeyHex, null);

        expect(connector.contactsForTest.single.customName, isNull);
        expect(connector.contactsForTest.single.name, _received);
        expect(await settings.loadCustomName(_contact().publicKeyHex), isNull);
      },
    );

    test(
      'T34c - an empty custom name is treated as a clear, not stored',
      () async {
        final settings = ContactSettingsStore()..setPublicKeyHex = _radioKey;
        connector.setContactSettingsKeyForTest(_radioKey);
        connector.contactsForTest.add(_contact(customName: _custom));

        await connector.setContactCustomName(_contact().publicKeyHex, '   ');

        expect(connector.contactsForTest.single.name, _received);
        expect(await settings.loadCustomName(_contact().publicKeyHex), isNull);
      },
    );
  });

  group('advert interaction, regression guards from 750.1 (#750)', () {
    test('T16 - copyWith of a received name leaves the display name alone', () {
      final c = _contact(
        customName: _custom,
      ).copyWith(receivedName: 'renamed-on-its-radio');

      expect(c.name, _custom);
      expect(c.receivedName, 'renamed-on-its-radio');
    });

    test('T17 + clearing afterwards reveals the NEWEST received name', () {
      final c = _contact(customName: _custom)
          .copyWith(receivedName: 'renamed-on-its-radio')
          .copyWith(clearCustomName: true);

      expect(c.name, 'renamed-on-its-radio');
    });

    test('T19 - a received-name update never writes a custom name', () {
      final c = _contact().copyWith(receivedName: 'new');

      expect(c.customName, isNull);
    });

    test('T20 + a card-added contact is not advert-verified', () {
      final carded = Contact(
        publicKey: _key(0x55),
        receivedName: 'Alice',
        type: advTypeChat,
        pathLength: -1,
        path: Uint8List(0),
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(carded.isAdvertVerified, isFalse);
      expect(carded.name, 'Alice');
    });

    test('T21 - a contact that has adverted IS verified', () {
      expect(_contact().isAdvertVerified, isTrue);
    });

    test('T22 + a rename that never propagated still shows the user label', () {
      // The owner's case: an operator renames their radio, the advert does not
      // come, so the received name stays stale. The user's own label is what
      // they see, and the stale received name is still there to show beside it.
      final c = _contact(customName: _custom);

      expect(c.name, _custom);
      expect(c.receivedName, _received);
    });
  });
}
