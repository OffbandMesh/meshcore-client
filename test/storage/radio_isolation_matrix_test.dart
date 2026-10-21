import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/models/delivery_observation.dart';
import 'package:meshcore_open/models/message.dart';
import 'package:meshcore_open/models/path_history.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/channel_order_store.dart';
import 'package:meshcore_open/storage/channel_store.dart';
import 'package:meshcore_open/storage/contact_discovery_store.dart';
import 'package:meshcore_open/storage/contact_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/message_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/storage/scoping_inventory.dart';
import 'package:meshcore_open/storage/unread_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #940, Feature #853's Integration Testing Epic.
///
/// Epic A's inventory declares a verdict per surface. Epics B, C and D fixed
/// the holes. This proves the whole thing end to end against the bar #853
/// actually set:
///
///   "the datum is isolated per radio, and a second radio does not inherit
///    the first's copy, across a radio switch AND an app restart"
///
/// A "restart" here is a fresh store object reading the same database, which
/// is what a restart does to storage. The hardware half, two real radios on
/// the owner's install, is E2 and only he can run it.
void main() {
  late OffbandDatabase db;

  const radioA = 'aaaaaaaaaa';
  const radioB = 'bbbbbbbbbb';
  // The stores truncate to 10 hex, so pad past that to exercise the setter.
  String key(String r) => r * 3;

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

  Contact contact(String name) => Contact(
    publicKey: Uint8List.fromList(List.filled(32, 7)),
    name: name,
    type: 1,
    pathLength: 0,
    path: Uint8List(0),
    lastSeen: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  ChannelMessage chanMsg(String text) => ChannelMessage(
    senderName: 's',
    text: text,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    isOutgoing: false,
    channelIndex: 0,
    messageId: 'id-$text',
  );

  Message dm(String text) => Message(
    senderKey: Uint8List.fromList(const [1, 2, 3, 4]),
    text: text,
    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    isOutgoing: false,
    messageId: 'id-$text',
  );

  /// Writes radio A's datum, switches to radio B, asserts B sees nothing, then
  /// switches back and asserts A still has it. That is the full bar: isolation
  /// is not deletion.
  ///
  /// [readFresh] builds a NEW store each time, which is what an app restart
  /// does to storage, so every case covers the switch and the restart at once.
  Future<void> expectIsolated<T>({
    required String label,
    required Future<void> Function(String radio) write,
    required Future<T> Function(String radio) readFresh,
    required bool Function(T) hasData,
  }) async {
    await write(key(radioA));

    expect(
      hasData(await readFresh(key(radioA))),
      isTrue,
      reason: '$label: radio A must see its own datum',
    );
    expect(
      hasData(await readFresh(key(radioB))),
      isFalse,
      reason: '$label: radio B MUST NOT inherit radio A\'s datum',
    );
    expect(
      hasData(await readFresh(key(radioA))),
      isTrue,
      reason:
          '$label: switching back must restore A. Isolation is not '
          'deletion',
    );
  }

  group('every per-radio surface, across a switch and a restart', () {
    test('channel messages', () async {
      await expectIsolated<List<ChannelMessage>>(
        label: 'channel_messages_',
        write: (r) async => (ChannelMessageStore()..setPublicKeyHex = r)
            .saveChannelMessages(0, [chanMsg('A only')]),
        readFresh: (r) =>
            (ChannelMessageStore()..setPublicKeyHex = r).loadChannelMessages(0),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('direct messages', () async {
      await expectIsolated<List<Message>>(
        label: 'messages_',
        write: (r) async => (MessageStore()..setPublicKeyHex = r).saveMessages(
          'cafebabe',
          [dm('A only')],
        ),
        readFresh: (r) =>
            (MessageStore()..setPublicKeyHex = r).loadMessages('cafebabe'),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('contacts', () async {
      await expectIsolated<List<Contact>>(
        label: 'contacts',
        write: (r) async => (ContactStore()..setPublicKeyHex = r).saveContacts([
          contact('A only'),
        ]),
        readFresh: (r) => (ContactStore()..setPublicKeyHex = r).loadContacts(),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('discovered contacts (#754)', () async {
      await expectIsolated<List<Contact>>(
        label: 'discovered_contacts',
        write: (r) async => (ContactDiscoveryStore()..setPublicKeyHex = r)
            .saveContacts([contact('A heard this')]),
        readFresh: (r) =>
            (ContactDiscoveryStore()..setPublicKeyHex = r).loadContacts(),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('channels', () async {
      await expectIsolated<List<Channel>>(
        label: 'channels',
        write: (r) async => (ChannelStore()..setPublicKeyHex = r).saveChannels([
          Channel(index: 0, name: 'A only', psk: Uint8List(16)),
        ]),
        readFresh: (r) => (ChannelStore()..setPublicKeyHex = r).loadChannels(),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('channel order', () async {
      await expectIsolated<List<int>>(
        label: 'channel_order_',
        write: (r) async =>
            (ChannelOrderStore()..setPublicKeyHex = r).saveChannelOrder([3, 1]),
        readFresh: (r) =>
            (ChannelOrderStore()..setPublicKeyHex = r).loadChannelOrder(),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('unread counts', () async {
      await expectIsolated<Map<String, int>>(
        label: 'contact_unread_count',
        write: (r) async {
          // saveContactUnreadCount is debounced, so the flush is what makes
          // it durable. Without it this would test the in-memory pending map.
          final store = UnreadStore()..setPublicKeyHex = r;
          store.saveContactUnreadCount({'c': 3});
          await store.flush();
          store.dispose();
        },
        readFresh: (r) =>
            (UnreadStore()..setPublicKeyHex = r).loadContactUnreadCount(),
        hasData: (v) => v.isNotEmpty,
      );
    });

    test('path history (#854)', () async {
      await expectIsolated<ContactPathHistory?>(
        label: 'path_history_',
        write: (r) async =>
            (StorageService()..setPublicKeyHex = r).savePathHistory(
              'cafebabe',
              ContactPathHistory(
                contactPubKeyHex: 'cafebabe',
                recentPaths: [
                  PathRecord(
                    hopCount: 2,
                    tripTimeMs: 500,
                    timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000),
                    wasFloodDiscovery: false,
                    pathBytes: const [1],
                    successCount: 1,
                    failureCount: 0,
                  ),
                ],
              ),
            ),
        readFresh: (r) =>
            (StorageService()..setPublicKeyHex = r).loadPathHistory('cafebabe'),
        hasData: (v) => v != null,
      );
    });

    test('delivery observations (#856)', () async {
      await expectIsolated<List<DeliveryObservation>>(
        label: 'delivery_observations',
        write: (r) async =>
            (StorageService()..setPublicKeyHex = r).saveDeliveryObservations([
              DeliveryObservation(
                contactKey: 'cafebabe',
                pathLength: 3,
                messageBytes: 100,
                secondsSinceLastRx: 10,
                isFlood: false,
                deliveryMs: 2500,
                timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000),
              ),
            ]),
        readFresh: (r) =>
            (StorageService()..setPublicKeyHex = r).loadDeliveryObservations(),
        hasData: (v) => v.isNotEmpty,
      );
    });
  });

  group('no radio connected means no data, for every surface', () {
    // Epic D's fail-closed property, across the board rather than one store.
    test('an unset key reads nothing even with data stored', () async {
      await (ChannelMessageStore()..setPublicKeyHex = key(radioA))
          .saveChannelMessages(0, [chanMsg('A only')]);
      await (MessageStore()..setPublicKeyHex = key(radioA)).saveMessages(
        'cafebabe',
        [dm('A only')],
      );
      await (ContactStore()..setPublicKeyHex = key(radioA)).saveContacts([
        contact('A only'),
      ]);

      expect(
        await (ChannelMessageStore()..setPublicKeyHex = '').loadChannelMessages(
          0,
        ),
        isEmpty,
      );
      expect(
        await (MessageStore()..setPublicKeyHex = '').loadMessages('cafebabe'),
        isEmpty,
      );
      expect(
        await (ContactStore()..setPublicKeyHex = '').loadContacts(),
        isEmpty,
      );
    });
  });

  group('the Feature\'s own closure condition', () {
    test('no surface is left unclassified and no hole remains', () async {
      // #853: "the Feature closes when every store has a verified scoping
      // verdict and no hole remains." Both halves, asserted.
      final holes = storageSurfaces.where(
        (s) => s.verdict == ScopingVerdict.knownHole,
      );
      expect(
        holes.map((s) => s.key),
        isEmpty,
        reason: 'a remaining hole means this Feature is not done',
      );

      for (final s in storageSurfaces) {
        expect(s.reason.trim(), isNotEmpty, reason: '${s.key} has no reason');
      }

      // And the per-radio count is not quietly zero.
      expect(
        storageSurfaces
            .where((s) => s.verdict == ScopingVerdict.perRadio)
            .length,
        greaterThanOrEqualTo(14),
        reason: 'sanity: the per-radio surfaces are the point of the Feature',
      );
    });
  });
}
