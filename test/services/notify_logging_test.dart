// #1122: the exported log must show what the client did with a channel
// notify mode (every save, every refused save, every change to the table by
// any path) and why each incoming channel message did or did not notify.

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_connector.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/models/channel.dart';
import 'package:meshcore_open/services/app_debug_log_service.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/services/message_retry_service.dart';
import 'package:meshcore_open/services/path_history_service.dart';
import 'package:meshcore_open/services/storage_service.dart';
import 'package:meshcore_open/storage/drift/blob_store.dart';
import 'package:meshcore_open/storage/drift/offband_database.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _channelInfoFrame(int index, String name, int seed) {
  final frame = Uint8List(50);
  frame[0] = respCodeChannelInfo;
  frame[1] = index;
  for (var i = 0; i < name.length; i++) {
    frame[2 + i] = name.codeUnitAt(i);
  }
  for (var i = 0; i < 16; i++) {
    frame[34 + i] = (seed + i) & 0xFF;
  }
  return frame;
}

Uint8List _channelMsgFrame(int channelIdx, String text) => Uint8List.fromList([
  respCodeChannelMsgRecvV3,
  0,
  0,
  0,
  channelIdx,
  1,
  txtTypePlain,
  0x40,
  0xE2,
  0x01,
  0x00,
  ...text.codeUnits,
]);

Channel _channel(int index, String name, int seed) => Channel(
  index: index,
  name: name,
  psk: Uint8List.fromList(List<int>.generate(16, (i) => (seed + i) & 0xFF)),
);

Future<void> _settle([int turns = 25]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const prefix = 'aabbccddee';
  const psk = '00112233445566778899aabbccddeeff';

  late AppDebugLogService log;

  List<AppDebugLogEntry> tagged(String tag) =>
      log.entries.where((e) => e.tag == tag).toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
    log = AppDebugLogService()..setEnabled(true);
    appLogger.initialize(log, enabled: true);
  });

  group('settings side', () {
    test('a save logs old mode, new mode and the read-back', () async {
      final s = AppSettingsService();
      await s.loadSettings();

      await s.setChannelNotifyMode(
        devicePrefix: prefix,
        pskHex: psk,
        channelName: 'test',
        mode: ChannelNotifyMode.off,
        channelIndex: 1,
      );

      final saved = tagged('NotifyMode').map((e) => e.message).toList();
      expect(
        saved,
        contains(
          'Notify mode saved for radio $prefix slot 1 "test" psk '
          '${AppSettingsService.pskFingerprint(psk)}: all (default, nothing '
          'saved) -> off; reads back off (saved)',
        ),
      );
      expect(
        saved.any((m) => m.startsWith('Channel notify table changed: {} ->')),
        isTrue,
      );
    });

    test('a save with no PSK is refused as an error, not silently', () async {
      final s = AppSettingsService();
      await s.loadSettings();

      await s.setChannelNotifyMode(
        devicePrefix: prefix,
        pskHex: null,
        channelName: 'test',
        mode: ChannelNotifyMode.off,
        channelIndex: 1,
      );

      final errors = tagged(
        'NotifyMode',
      ).where((e) => e.level == AppDebugLogLevel.error).toList();
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('NOT saved'));
      expect(errors.single.message, contains('channel has no PSK'));
      expect(s.settings.channelNotifyModesByRadio, isEmpty);
    });

    test('a save with no radio key is refused as an error', () async {
      final s = AppSettingsService();
      await s.loadSettings();

      await s.setChannelNotifyMode(
        devicePrefix: '',
        pskHex: psk,
        channelName: 'test',
        mode: ChannelNotifyMode.off,
      );

      final errors = tagged(
        'NotifyMode',
      ).where((e) => e.level == AppDebugLogLevel.error);
      expect(errors.single.message, contains('no radio key'));
    });

    test('unreadable saved settings are reported as an error', () async {
      SharedPreferences.setMockInitialValues({'app_settings': '{not json'});
      PrefsManager.reset();
      await PrefsManager.initialize();
      final s = AppSettingsService();
      await s.loadSettings();

      s.logLoadReport();

      expect(
        tagged('Settings').where((e) => e.level == AppDebugLogLevel.error),
        hasLength(1),
      );
    });

    test('the PSK fingerprint is short and does not carry the PSK', () {
      final fp = AppSettingsService.pskFingerprint(psk);
      expect(fp, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(psk.contains(fp), isFalse);
      expect(AppSettingsService.pskFingerprint(null), 'none');
    });
  });

  group('notify decision', () {
    late OffbandDatabase db;
    late AppSettingsService settings;
    late MeshCoreConnector c;

    setUp(() async {
      db = OffbandDatabase(NativeDatabase.memory());
      BlobStore.overrideForTest(BlobStore(db));
      settings = AppSettingsService();
      await settings.loadSettings();
      c = MeshCoreConnector();
      c.initialize(
        retryService: MessageRetryService(),
        pathHistoryService: PathHistoryService(StorageService()),
        appSettingsService: settings,
        appDebugLogService: log,
      );
      c.sendFrameOverrideForTest = (_) {};
      c.setConnectedForTest();
      c.setSelfPublicKeyForTest(
        Uint8List.fromList(List<int>.generate(32, (i) => i)),
      );
      c.wireMessageStoreForTest();
      await c.getChannels(force: true, maxChannels: 2);
      c.handleFrameForTest(_channelInfoFrame(0, 'Public', 10));
      await _settle(2);
      c.handleFrameForTest(_channelInfoFrame(1, 'test', 50));
      await _settle();
    });

    tearDown(() async {
      BlobStore.clearTestOverride();
      await db.close();
    });

    List<String> decisions() => tagged(
      'Notification',
    ).map((e) => e.message).where((m) => m.startsWith('CHAN NOTIFY')).toList();

    test('an Off channel logs suppressed, with the saved mode', () async {
      final testCh = _channel(1, 'test', 50);
      await settings.setChannelNotifyMode(
        devicePrefix: c.selfPublicKeyHex,
        pskHex: testCh.pskHex,
        channelName: 'test',
        mode: ChannelNotifyMode.off,
        channelIndex: 1,
      );

      c.handleFrameForTest(_channelMsgFrame(1, 'B: hi'));
      await _settle();

      final line = decisions().single;
      expect(line, contains('slot 1 "test"'));
      expect(
        line,
        contains('psk ${AppSettingsService.pskFingerprint(testCh.pskHex)}'),
      );
      expect(line, contains('(live list)'));
      expect(line, endsWith('mode off (saved) -> suppressed, mode off'));
    });

    test(
      'a channel with nothing saved logs posting, with the default',
      () async {
        c.handleFrameForTest(_channelMsgFrame(0, 'B: hi'));
        await _settle();

        expect(
          decisions().single,
          endsWith('mode all (default, nothing saved) -> posting'),
        );
      },
    );

    test(
      'app-wide channel notifications off is logged as the reason',
      () async {
        await settings.updateSettings(
          settings.settings.copyWith(notifyOnNewChannelMessage: false),
        );

        c.handleFrameForTest(_channelMsgFrame(0, 'B: hi'));
        await _settle();

        expect(decisions().single, contains('suppressed, app setting off'));
      },
    );
  });
}
