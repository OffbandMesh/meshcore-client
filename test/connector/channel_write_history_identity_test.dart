// #1128 on top of #1026/#1063: what a confirmed channel write does to
// PSK-keyed history.
//
// History is never kept hidden. A key change asks: Keep moves the old key's
// history (and phone notify mode) to the new key, Delete removes it, both as
// soon as the radio confirms the clear. A different channel written over a
// slot is settled by the next sync that saw every slot: history no channel on
// the radio shows is deleted, and a channel the firmware moved keeps its own.
// A radio with erased slots (the Restore case) or a partial sync deletes
// nothing. Exercised through the real store, not the in-memory map.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/channel_message_store.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List psk(int fill) => Uint8List.fromList(List<int>.filled(16, fill));

List<int> channelInfo(int index, String name, Uint8List key) => [
  respCodeChannelInfo,
  index,
  ...name.codeUnits,
  ...List<int>.filled(32 - name.length, 0),
  ...key,
];

ChannelMessage msg(String text) => ChannelMessage(
  senderName: 's',
  text: text,
  timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
  isOutgoing: false,
  channelIndex: 0,
  messageId: text,
);

const int slots = 2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OffbandDatabase db;
  late MeshCoreConnector connector;
  late AppSettingsService settings;
  late List<Uint8List> sent;
  late AppDebugLogService log;

  /// What the exported log says about the hidden-history check, newest last.
  List<String> historyChecks() => [
    for (final e in log.entries)
      if (e.message.startsWith('Hidden channel history check')) e.message,
  ];

  final weather = Channel(index: 0, name: 'Weather', psk: psk(0x22));
  final empty = Uint8List(16);

  /// History stored under a key, whatever slot that channel is in.
  ChannelMessageStore historyOf(Uint8List key) => ChannelMessageStore()
    ..setPublicKeyHex = connector.selfPublicKeyHex
    ..channelPskResolver = (_) => Channel(index: 0, name: '', psk: key).pskHex;

  Future<void> settle([int turns = 1]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void ok() => connector.handleFrameForTest([respCodeOk]);

  /// The radio answers a sync of every slot with [bySlot] (null = empty).
  Future<void> radioHolds(
    List<(String, Uint8List)?> bySlot, {
    bool start = true,
  }) async {
    if (start) await connector.getChannels(maxChannels: slots, force: true);
    for (var i = 0; i < slots; i++) {
      final c = bySlot[i];
      connector.handleFrameForTest(channelInfo(i, c?.$1 ?? '', c?.$2 ?? empty));
      await settle();
    }
    await settle(50);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    sent = [];
    connector = MeshCoreConnector();
    connector.sendFrameOverrideForTest = sent.add;
    connector.setConnectedForTest();
    connector.setSelfPublicKeyForTest(
      Uint8List.fromList(List<int>.generate(32, (i) => i)),
    );
    connector.wireMessageStoreForTest();
    settings = AppSettingsService();
    await settings.loadSettings();
    connector.setAppSettingsServiceForTest(settings);
    log = AppDebugLogService()..setEnabled(true);
    appLogger.initialize(log, enabled: true);
    connector.setAppDebugLogServiceForTest(log);

    // Device info says the radio has [slots] channel slots.
    connector.handleFrameForTest([respCodeDeviceInfo, 14, 100, slots]);
    await settle();

    await radioHolds([(weather.name, weather.psk), null]);
    expect(connector.channels.first.pskHex, weather.pskHex);

    await historyOf(weather.psk).saveChannelMessages(0, [msg('kept')]);
    expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  /// Runs a key-change edit of Weather to [newKey], with the radio answering
  /// the clear OK and the add with [addReply].
  Future<ChannelWrite> changeKey(
    Uint8List newKey,
    KeyChangeHistory history, {
    List<int>? addReply,
  }) async {
    int setFrames() =>
        sent.where((f) => f.isNotEmpty && f[0] == cmdSetChannel).length;
    final before = setFrames();
    final edit = connector.editChannel(
      weather,
      'Weather',
      newKey,
      history: history,
    );
    Future<void> untilSetFrames(int n) async {
      // The history move can decode on another isolate, so wait in real time
      // for the frame rather than a fixed number of microtask turns.
      for (var i = 0; i < 500 && setFrames() < before + n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(setFrames(), before + n, reason: 'set-channel frame $n sent');
    }

    await untilSetFrames(1);
    ok(); // the clear
    await untilSetFrames(2);
    connector.handleFrameForTest(addReply ?? [respCodeOk]);
    return edit;
  }

  group('key change', () {
    test(
      'Keep moves the history to the new key, none left under the old',
      () async {
        expect(
          await changeKey(psk(0x99), KeyChangeHistory.keep),
          ChannelWrite.ok,
        );
        await radioHolds([('Weather', psk(0x99)), null], start: false);

        expect(await historyOf(psk(0x99)).loadChannelMessages(0), hasLength(1));
        expect(await historyOf(weather.psk).loadChannelMessages(0), isEmpty);
      },
    );

    test('Keep carries the phone notify mode to the new key', () async {
      await settings.setChannelNotifyMode(
        devicePrefix: connector.selfPublicKeyHex,
        pskHex: weather.pskHex,
        channelName: 'Weather',
        mode: ChannelNotifyMode.off,
      );

      await changeKey(psk(0x99), KeyChangeHistory.keep);

      final newHex = Channel(index: 0, name: '', psk: psk(0x99)).pskHex;
      expect(
        settings.channelNotifyMode(
          devicePrefix: connector.selfPublicKeyHex,
          pskHex: newHex,
        ),
        ChannelNotifyMode.off,
      );
      expect(
        settings
            .resolveChannelNotifyMode(
              devicePrefix: connector.selfPublicKeyHex,
              pskHex: weather.pskHex,
            )
            .source,
        'default, nothing saved',
      );
    });

    test('Delete removes the old key\'s history and moves nothing', () async {
      expect(
        await changeKey(psk(0x99), KeyChangeHistory.delete),
        ChannelWrite.ok,
      );

      expect(await historyOf(weather.psk).loadChannelMessages(0), isEmpty);
      expect(await historyOf(psk(0x99)).loadChannelMessages(0), isEmpty);
    });

    test(
      'a key change with no answer is refused before anything is sent',
      () async {
        sent.clear();
        expect(
          () => connector.editChannel(weather, 'Weather', psk(0x99)),
          throwsArgumentError,
        );
        expect(sent, isEmpty);
        expect(
          await historyOf(weather.psk).loadChannelMessages(0),
          hasLength(1),
        );
      },
    );

    test('a refused clear leaves history where it was', () async {
      final edit = connector.editChannel(
        weather,
        'Weather',
        psk(0x99),
        history: KeyChangeHistory.delete,
      );
      await settle();
      connector.handleFrameForTest([respCodeErr, errCodeNotFound]);

      expect(await edit, ChannelWrite.rejected);
      expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
    });

    test('a same-key rename asks nothing and keeps history', () async {
      final edit = connector.editChannel(weather, 'Wx', weather.psk);
      await settle();
      ok();

      expect(await edit, ChannelWrite.ok);
      expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
    });

    test('Keep with a failed add holds the history for a re-add, '
        'through the sync that follows', () async {
      expect(
        await changeKey(
          psk(0x99),
          KeyChangeHistory.keep,
          addReply: [respCodeErr, errCodeNotFound],
        ),
        ChannelWrite.clearedNotAdded,
      );
      // The write's own re-read: the slot is empty on the radio now. Another
      // channel is there, so the no-channels guard is not what spares it.
      await radioHolds([null, ('Other', psk(0x33))], start: false);

      expect(await historyOf(psk(0x99)).loadChannelMessages(0), hasLength(1));
    });
  });

  group('kept history a key change could not land', () {
    test('a Keep whose move fails says so, and the old key survives the '
        'sync that follows', () async {
      final oldKey =
          'channel_messages_${connector.selfPublicKeyHex.substring(0, 10)}'
          'psk_${weather.pskHex}';
      await BlobStore.instance.deleteMessageRows(oldKey);
      BlobStore.instance.resetMigratedKeyCache();
      await BlobStore.instance.write('__msgrows_migrated', '[]');
      await BlobStore.instance.write(oldKey, 'not json');
      BlobStore.instance.resetMigratedKeyCache();

      expect(
        await changeKey(psk(0x99), KeyChangeHistory.keep),
        ChannelWrite.historyNotMoved,
      );
      await radioHolds([('Weather', psk(0x99)), null], start: false);

      expect(await BlobStore.instance.read(oldKey), 'not json');
    });

    test(
      'a spared key is judged normally once the radio holds it again',
      () async {
        await changeKey(
          psk(0x99),
          KeyChangeHistory.keep,
          addReply: [respCodeErr, errCodeNotFound],
        );
        await radioHolds([null, ('Other', psk(0x33))], start: false);
        // Re-added (here: the radio reports it), then deleted elsewhere.
        await radioHolds([('Weather', psk(0x99)), null]);
        await radioHolds([('Other', psk(0x33)), null]);

        expect(await historyOf(psk(0x99)).loadChannelMessages(0), isEmpty);
      },
    );
  });

  group('a different channel written over a slot', () {
    test('its old occupant\'s history goes once a full sync shows the radio '
        'no longer holds it', () async {
      final write = connector.setChannel(0, 'Other', psk(0x33), refresh: false);
      ok();
      expect(await write, ChannelWrite.ok);

      await radioHolds([('Other', psk(0x33)), null]);

      expect(await historyOf(weather.psk).loadChannelMessages(0), isEmpty);
      expect(
        historyChecks().last,
        allOf(contains('against 1 channel(s)'), contains('1 deleted')),
      );
    });

    test(
      'a channel the firmware moved out of the way keeps its history',
      () async {
        final write = connector.setChannel(
          0,
          'Other',
          psk(0x33),
          refresh: false,
        );
        ok();
        expect(await write, ChannelWrite.ok);

        await radioHolds([('Other', psk(0x33)), (weather.name, weather.psk)]);

        expect(
          await historyOf(weather.psk).loadChannelMessages(0),
          hasLength(1),
        );
      },
    );
  });

  group('syncs that cannot judge history delete nothing', () {
    test('erased slots (the Restore case)', () async {
      await radioHolds([('\u{FFFD}', psk(0xFF)), null]);

      expect(connector.canRestoreChannelsToRadio, isTrue);
      expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
      expect(historyChecks().last, contains('skipped'));
      expect(historyChecks().last, contains('erased slots'));
    });

    test('a sync asked for fewer slots than the radio has', () async {
      await connector.getChannels(maxChannels: 1, force: true);
      connector.handleFrameForTest(channelInfo(0, 'Other', psk(0x33)));
      await settle(50);

      expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
      expect(
        historyChecks().last,
        contains(
          'skipped for radio 0001020304: this sync read 1 of the '
          'radio\'s 2 slots',
        ),
      );
    });

    test('a radio that reports no channels at all', () async {
      await radioHolds([null, null]);

      expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
    });
  });

  test('a confirmed delete removes the channel\'s history', () async {
    final delete = connector.deleteChannel(0, refresh: false);
    ok();

    expect(await delete, ChannelWrite.ok);
    expect(await historyOf(weather.psk).loadChannelMessages(0), isEmpty);
  });

  test('a refused delete keeps it', () async {
    final delete = connector.deleteChannel(0, refresh: false);
    connector.handleFrameForTest([respCodeErr, errCodeNotFound]);

    expect(await delete, ChannelWrite.rejected);
    expect(await historyOf(weather.psk).loadChannelMessages(0), hasLength(1));
  });
}
