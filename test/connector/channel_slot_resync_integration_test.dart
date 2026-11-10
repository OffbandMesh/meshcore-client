// #1064 (Epic C of #1061): end-to-end slot-shuffle scenarios across Epic A
// (#1062, fail-closed sync + ingress barrier) and Epic B (#1063, per-slot
// state never crosses identities). The first test is the #1060 bug-validation
// scenario: a wipe + config re-import rearranged the device's channel slots,
// #wardriving notified with its mode off, and #test messages rendered inside
// the private channel.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/models/channel_message.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _channelInfoFrame({
  required int index,
  required String name,
  required int pskSeed,
}) {
  final frame = Uint8List(50);
  frame[0] = respCodeChannelInfo;
  frame[1] = index;
  final nameBytes = name.codeUnits;
  for (var i = 0; i < nameBytes.length && i < 31; i++) {
    frame[2 + i] = nameBytes[i];
  }
  for (var i = 0; i < 16; i++) {
    frame[34 + i] = (pskSeed + i) & 0xFF;
  }
  return frame;
}

Uint8List _v3ChannelMsgFrame({required int channelIdx, String text = 'A: hi'}) {
  return Uint8List.fromList([
    respCodeChannelMsgRecvV3,
    0, 0, 0,
    channelIdx,
    1, // path_len: 1 hop, width 1
    txtTypePlain,
    0x40, 0xE2, 0x01, 0x00,
    ...text.codeUnits,
  ]);
}

Channel _channel(int index, String name, int pskSeed) {
  final psk = Uint8List.fromList(
    List<int>.generate(16, (i) => (pskSeed + i) & 0xFF),
  );
  return Channel(index: index, name: name, psk: psk);
}

typedef _NotifyDecision = ({
  int channelIndex,
  String channelName,
  String? pskHex,
  ChannelNotifyMode? mode,
});

Future<void> _settle([int turns = 25]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OffbandDatabase db;
  late AppSettingsService settings;
  late MeshCoreConnector c;
  late List<_NotifyDecision> notifyDecisions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    db = OffbandDatabase(NativeDatabase.memory());
    BlobStore.overrideForTest(BlobStore(db));

    settings = AppSettingsService();
    await settings.loadSettings();

    c = MeshCoreConnector();
    c.initialize(
      retryService: MessageRetryService(),
      pathHistoryService: PathHistoryService(StorageService()),
      appSettingsService: settings,
    );
    c.sendFrameOverrideForTest = (_) {};
    c.setConnectedForTest();
    c.setSelfPublicKeyForTest(
      Uint8List.fromList(List<int>.generate(32, (i) => i)),
    );
    c.wireMessageStoreForTest();

    notifyDecisions = [];
    c.channelNotifyProbeForTest = (index, name, pskHex, mode) {
      notifyDecisions.add((
        channelIndex: index,
        channelName: name,
        pskHex: pskHex,
        mode: mode,
      ));
    };
  });

  tearDown(() async {
    BlobStore.clearTestOverride();
    await db.close();
  });

  Future<void> syncWith(List<Channel> deviceArrangement, {int? max}) async {
    await c.getChannels(
      force: true,
      maxChannels: max ?? deviceArrangement.length,
    );
    for (final ch in deviceArrangement) {
      c.handleFrameForTest(
        _channelInfoFrame(index: ch.index, name: ch.name, pskSeed: ch.psk[0]),
      );
      await _settle(2);
    }
    await _settle();
  }

  test('#1060 bug validation: wipe + re-import with shuffled slots', () async {
    // Before the wipe this radio had: slot0 #wardriving (notify OFF),
    // slot1 #test, slot2 the private channel (an old conversation on screen).
    final wardriving = _channel(0, 'wardriving', 40);
    final testCh = _channel(1, 'test', 50);
    final private = _channel(2, 'Private', 60);
    c.seedCachedChannelsForTest([wardriving, testCh, private]);
    await settings.setChannelNotifyMode(
      devicePrefix: c.selfPublicKeyHex,
      pskHex: wardriving.pskHex,
      channelName: wardriving.name,
      mode: ChannelNotifyMode.off,
    );
    c.channelMessagesForTest[2] = [
      ChannelMessage(
        senderName: 'friend',
        text: 'old private talk',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
        isOutgoing: false,
        channelIndex: 2,
        messageId: 'old-private',
      ),
    ];

    // The re-imported config put the same channels in DIFFERENT slots.
    await syncWith([
      _channel(0, 'test', 50),
      _channel(1, 'Private', 60),
      _channel(2, 'wardriving', 40),
    ]);

    // The list matches the device, and every slot's change was surfaced.
    expect(c.channels.map((ch) => ch.name), ['test', 'Private', 'wardriving']);
    expect(c.slotIdentityChanges, hasLength(3));
    expect(c.unconfirmedChannelSlots, isEmpty);

    // The old private conversation did not stay behind in slot 2, which
    // #wardriving now occupies.
    expect(c.channelMessagesForTest[2] ?? const <ChannelMessage>[], isEmpty);

    // A #test message files under #test's slot and is evaluated against
    // #test's PSK (default mode), not against whatever used to live there.
    c.handleFrameForTest(_v3ChannelMsgFrame(channelIdx: 0, text: 'B: to test'));
    await _settle();
    expect(c.channelMessagesForTest[0]!.single.text, 'to test');
    expect(
      c.channelMessagesForTest[1] ?? const <ChannelMessage>[],
      isEmpty,
      reason: '#test traffic must not render inside the private channel',
    );
    final testDecision = notifyDecisions.single;
    expect(testDecision.channelName, 'test');
    expect(testDecision.pskHex, testCh.pskHex);
    expect(testDecision.mode, ChannelNotifyMode.all);

    // A #wardriving message follows #wardriving's OFF mode to its NEW slot:
    // the #1060 complaint was notifications firing with the mode off.
    notifyDecisions.clear();
    c.handleFrameForTest(_v3ChannelMsgFrame(channelIdx: 2, text: 'B: war'));
    await _settle();
    expect(c.channelMessagesForTest[2]!.single.text, 'war');
    final warDecision = notifyDecisions.single;
    expect(warDecision.pskHex, wardriving.pskHex);
    expect(
      warDecision.mode,
      ChannelNotifyMode.off,
      reason: 'the OFF mode belongs to the PSK and must ride along to slot 2',
    );
  });

  test('manual reorder on the device: history follows the channel, '
      'not the slot', () async {
    // First sync: Alpha in slot 0, Beta in slot 1. A message lands in Alpha
    // and is persisted under Alpha's PSK identity.
    await syncWith([_channel(0, 'Alpha', 10), _channel(1, 'Beta', 30)]);
    c.handleFrameForTest(
      _v3ChannelMsgFrame(channelIdx: 0, text: 'A: hello alpha'),
    );
    await _settle();
    expect(c.channelMessagesForTest[0]!.single.text, 'hello alpha');
    // Let the unawaited persistence land before the reorder.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The operator swaps the slots on the device; the client re-syncs.
    await syncWith([_channel(0, 'Beta', 30), _channel(1, 'Alpha', 10)]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await _settle();

    expect(c.channels.map((ch) => ch.name), ['Beta', 'Alpha']);
    expect(
      c.channelMessagesForTest[0] ?? const <ChannelMessage>[],
      isEmpty,
      reason: "Alpha's conversation must not render under Beta",
    );
    expect(
      (c.channelMessagesForTest[1] ?? const <ChannelMessage>[]).map(
        (m) => m.text,
      ),
      ['hello alpha'],
      reason: "Alpha's PSK-keyed history reloads at its new slot",
    );
  });

  test('flaky sync mid-reconnect: held traffic files only after a '
      'confirming sync, against the right PSK', () async {
    final alpha = _channel(0, 'Alpha', 10);
    final beta = _channel(1, 'Beta', 30);
    c.seedCachedChannelsForTest([alpha, beta]);
    await settings.setChannelNotifyMode(
      devicePrefix: c.selfPublicKeyHex,
      pskHex: beta.pskHex,
      channelName: beta.name,
      mode: ChannelNotifyMode.off,
    );

    // The sync answers slot 0, a message for slot 1 arrives mid-sync, and
    // slot 1 never answers.
    await c.getChannels(maxChannels: 2);
    c.handleFrameForTest(
      _channelInfoFrame(index: 0, name: 'Alpha', pskSeed: 10),
    );
    await _settle(2);
    c.handleFrameForTest(_v3ChannelMsgFrame(channelIdx: 1, text: 'B: held'));
    for (var i = 0; i <= 3; i++) {
      c.handleChannelSyncTimeoutForTest(1);
      await _settle(2);
    }
    await _settle();

    expect(c.unconfirmedChannelSlots, {1});
    expect(
      c.channelMessagesForTest[1],
      isNull,
      reason: 'a message for an unconfirmed slot must not file by raw index',
    );
    expect(
      notifyDecisions.where((d) => d.channelIndex == 1 && d.mode != null),
      isEmpty,
      reason: 'no notify decision can be made for an unconfirmed slot',
    );

    // The reconnect-style retry confirms both slots; the held message now
    // files, and Beta's OFF mode is evaluated against Beta's own PSK.
    notifyDecisions.clear();
    await syncWith([alpha, beta]);

    expect(c.unconfirmedChannelSlots, isEmpty);
    expect(c.channels.map((ch) => ch.name), ['Alpha', 'Beta']);
    expect(c.channelMessagesForTest[1]!.single.text, 'held');
    final decision = notifyDecisions.single;
    expect(decision.channelIndex, 1);
    expect(decision.pskHex, beta.pskHex);
    expect(decision.mode, ChannelNotifyMode.off);
  });

  test(
    'identity-change reload does not hide a message flushed meanwhile',
    () async {
      // Beta builds history at slot 1, then moves to slot 0. A live message for
      // slot 0 arrives MID-resync (held), so the flush files it while the
      // identity-change reload is still reading the store. Both must be visible
      // afterwards: the reload merges, it does not clobber (#1063 review).
      await syncWith([_channel(0, 'Alpha', 10), _channel(1, 'Beta', 30)]);
      c.handleFrameForTest(
        _v3ChannelMsgFrame(channelIdx: 1, text: 'B: beta history'),
      );
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await c.getChannels(force: true, maxChannels: 2);
      // Mid-resync: the barrier is closed, so this is held, and the flush will
      // file it in the same turn that starts the slot-0 reload.
      c.handleFrameForTest(
        _v3ChannelMsgFrame(channelIdx: 0, text: 'B: live during sync'),
      );
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Beta', pskSeed: 30),
      );
      await _settle(2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 1, name: 'Alpha', pskSeed: 10),
      );
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _settle();

      final slot0Texts =
          (c.channelMessagesForTest[0] ?? const <ChannelMessage>[])
              .map((m) => m.text)
              .toSet();
      expect(
        slot0Texts,
        containsAll(<String>{'beta history', 'live during sync'}),
        reason:
            'the reload must merge with what the flush just filed, '
            'not clobber it',
      );
    },
  );

  test(
    'outgoing send to an unconfirmed slot is refused, not orphaned',
    () async {
      final alpha = _channel(0, 'Alpha', 10);
      final beta = _channel(1, 'Beta', 30);
      c.seedCachedChannelsForTest([alpha, beta]);

      // Slot 0 confirms, slot 1 never does.
      await c.getChannels(maxChannels: 2);
      c.handleFrameForTest(
        _channelInfoFrame(index: 0, name: 'Alpha', pskSeed: 10),
      );
      await _settle(2);
      for (var i = 0; i <= 3; i++) {
        c.handleChannelSyncTimeoutForTest(1);
        await _settle(2);
      }
      await _settle();
      expect(c.unconfirmedChannelSlots, {1});
      expect(c.canSendOnChannel(0), isTrue);
      expect(c.canSendOnChannel(1), isFalse);

      final sentFrames = <Uint8List>[];
      c.sendFrameOverrideForTest = sentFrames.add;
      await c.sendChannelMessage(beta, 'must not be written');
      await _settle();

      expect(sentFrames, isEmpty, reason: 'nothing may go to the radio');
      expect(
        c.channelMessagesForTest[1] ?? const <ChannelMessage>[],
        isEmpty,
        reason:
            'the refused message must not be filed (a persisted copy would '
            'fall back to the legacy slot-index key and be orphaned)',
      );
    },
  );

  test(
    'held frames never cross radios; they flush when their radio returns',
    () async {
      // Radio X delivers a message before its list is confirmed; the frame is
      // held. The user then connects radio Y: Y's sync must NOT flush X's frame
      // into Y's conversations. When X reconnects and syncs, the frame files.
      final radioX = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final radioY = Uint8List.fromList(List<int>.generate(32, (i) => 99 + i));

      c.handleFrameForTest(
        _v3ChannelMsgFrame(channelIdx: 0, text: 'A: from X'),
      );
      await _settle();

      // Switch to radio Y and complete its sync.
      c.resetConnectionHandshakeStateForTest();
      c.setConnectedForTest();
      c.setSelfPublicKeyForTest(radioY);
      c.wireMessageStoreForTest();
      await syncWith([_channel(0, 'Gamma', 70)]);
      expect(
        c.channelMessagesForTest[0] ?? const <ChannelMessage>[],
        isEmpty,
        reason: "radio X's held frame must not file into radio Y's channel",
      );

      // Back to radio X: its held frame now files against its own list.
      c.resetConnectionHandshakeStateForTest();
      c.setConnectedForTest();
      c.setSelfPublicKeyForTest(radioX);
      c.wireMessageStoreForTest();
      await syncWith([_channel(0, 'Alpha', 10)]);
      expect(
        (c.channelMessagesForTest[0] ?? const <ChannelMessage>[]).map(
          (m) => m.text,
        ),
        ['from X'],
      );
    },
  );
}
