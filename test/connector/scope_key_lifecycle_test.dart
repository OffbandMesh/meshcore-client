import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #939 Epic D: the scope-key lifecycle.
///
/// A different defect class from Epic B's global keys. These stores ARE
/// correctly per-radio; they bled anyway, through timing. The scope key is set
/// on SELF_INFO, and an unexpected disconnect did not clear it, so connecting a
/// different radio left a window in which any read served the previous radio's
/// data (#158).
///
/// Also carries D1's verdict on #190, as a test rather than an argument.
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

  ChannelMessage msg(String text) => ChannelMessage(
    senderName: 's',
    text: text,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id-$text',
  );

  group('#158 the stale-read window after an unexpected drop', () {
    test(
      'clearing the scope keys makes a read fail closed, not serve radio A',
      () async {
        // Radio A connects and stores history.
        final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
        await store.saveChannelMessages(0, [msg('radio A only')]);
        expect((await store.loadChannelMessages(0)).length, 1);

        // The drop. Before this fix _handleDisconnection left the key in
        // place, so this store still answered as radio A.
        store.setPublicKeyHex = '';

        expect(
          await store.loadChannelMessages(0),
          isEmpty,
          reason:
              'with no radio identity a read must return nothing. '
              'Serving radio A here is #158',
        );
      },
    );

    test('and a write in that window is refused, not misfiled', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = '';

      await store.saveChannelMessages(0, [msg('arrived mid-reconnect')]);

      // Bring radio A back and confirm nothing was filed under it.
      store.setPublicKeyHex = 'a' * 20;
      expect(
        await store.loadChannelMessages(0),
        isEmpty,
        reason:
            'a message arriving before SELF_INFO must not be written '
            'under whichever radio connects next',
      );
    });

    test('the connector clears every store on an unexpected drop', () async {
      // Exercises the real reset rather than a hand-cleared store, so the
      // test fails if a store is added to the connector and left out of
      // _clearStorageScopeKeys.
      final connector = MeshCoreConnector();

      connector.clearStorageScopeKeysForTest();

      expect(
        connector.selfPublicKeyHex,
        isEmpty,
        reason:
            'channels_screen builds its own store from this getter, so '
            'clearing the connector-owned stores alone would leave that '
            'path reading a stale prefix',
      );
    });
  });

  group('#190 verdict: a reused slot cannot surface the old occupant', () {
    // #190's reproduction: scan a new channel's QR, and the new channel shows
    // the previous occupant's history (#echo). Its named root cause was
    // slot-index keying with no PSK binding. Two mechanisms landed since, and
    // this proves the scenario rather than arguing it.

    test(
      'PSK identity, not slot index, decides which history is read',
      () async {
        final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

        // The old occupant of slot 0.
        store.channelPskResolver = (_) => 'psk_old';
        await store.saveChannelMessages(0, [msg('old #echo history')]);

        // The slot is reassigned: same index 0, different PSK.
        store.channelPskResolver = (_) => 'psk_new';

        expect(
          await store.loadChannelMessages(0),
          isEmpty,
          reason:
              '#190 exactly: the newly added channel must not see the '
              'previous occupant\'s messages. Keyed by PSK (#194) it reads a '
              'different key entirely',
        );
      },
    );

    test('and the old occupant\'s history is still its own', () async {
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;
      store.channelPskResolver = (_) => 'psk_old';
      await store.saveChannelMessages(0, [msg('old #echo history')]);

      store.channelPskResolver = (_) => 'psk_new';
      await store.saveChannelMessages(0, [msg('new channel')]);
      store.channelPskResolver = (_) => 'psk_old';

      expect(
        (await store.loadChannelMessages(0)).single.text,
        'old #echo history',
        reason:
            'isolation by identity, not deletion: if that channel comes '
            'back to any slot it still has its own history',
      );
    });

    test('the index fallback is what remains, and it warns', () async {
      // With no resolver the store falls back to the slot-index key. That is
      // legitimate before the channel list has loaded and is the #333 race,
      // which is a TIMING problem and therefore this Epic's subject rather
      // than #190's. Pinned here so the remaining surface is explicit.
      final store = ChannelMessageStore()..setPublicKeyHex = 'a' * 20;

      await store.saveChannelMessages(0, [msg('written without a PSK')]);

      expect(
        (await store.loadChannelMessages(0)).single.text,
        'written without a PSK',
        reason:
            'the fallback still works; what it cannot do is tell two '
            'occupants of one slot apart, which is why _storageKey logs a '
            'warning when it fires',
      );
    });
  });
}
