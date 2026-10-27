import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/app_settings.dart';
import 'package:meshcore_open/services/app_settings_service.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// #839: channel notify modes must be scoped per radio (connected device-key
// prefix), the bare slot-index fallback is gone, and setting All must truly
// reset. Positive AND negative cases per the owner acceptance.
void main() {
  const prefixA = 'aaaaaaaaaa';
  const prefixB = 'bbbbbbbbbb';
  const pskX = '0123456789abcdef0123456789abcdef';
  const pskPublic = 'ffffffffffffffffffffffffffffffff';

  AppSettingsService service() => AppSettingsService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  test('a mode set on radio A does not bleed into radio B', () async {
    final s = service();
    await s.loadSettings();

    await s.setChannelNotifyMode(
      devicePrefix: prefixA,
      pskHex: pskX,
      channelName: 'Test',
      mode: ChannelNotifyMode.off,
    );

    expect(
      s.channelNotifyMode(devicePrefix: prefixA, pskHex: pskX),
      ChannelNotifyMode.off,
    );
    // Same channel PSK, different radio: independent, defaults to All.
    expect(
      s.channelNotifyMode(devicePrefix: prefixB, pskHex: pskX),
      ChannelNotifyMode.all,
    );
  });

  test('set-and-back to All truly resets (no stale alias wins)', () async {
    final s = service();
    await s.loadSettings();

    await s.setChannelNotifyMode(
      devicePrefix: prefixA,
      pskHex: pskX,
      channelName: 'Test',
      mode: ChannelNotifyMode.off,
    );
    await s.setChannelNotifyMode(
      devicePrefix: prefixA,
      pskHex: pskX,
      channelName: 'Test',
      mode: ChannelNotifyMode.all,
    );

    expect(
      s.channelNotifyMode(devicePrefix: prefixA, pskHex: pskX),
      ChannelNotifyMode.all,
    );
    // All is the default and is not stored.
    expect(
      s.settings.channelNotifyModesByRadio[prefixA]?.containsKey(pskX) ?? false,
      isFalse,
    );
  });

  test(
    'unknown scope resolves All and persists nothing (no index fallback)',
    () async {
      final s = service();
      await s.loadSettings();

      // PSK not yet known (pre-sync): resolve All, never key by slot index.
      expect(
        s.channelNotifyMode(devicePrefix: prefixA, pskHex: null),
        ChannelNotifyMode.all,
      );
      expect(
        s.channelNotifyMode(devicePrefix: '', pskHex: pskX),
        ChannelNotifyMode.all,
      );

      // Setting with no PSK is a no-op, not an index-keyed write.
      await s.setChannelNotifyMode(
        devicePrefix: prefixA,
        pskHex: null,
        channelName: 'Test',
        mode: ChannelNotifyMode.off,
      );
      expect(
        s.settings.channelNotifyModesByRadio[prefixA] ?? const {},
        isEmpty,
      );
    },
  );

  test('the mode survives an app restart (reload from prefs)', () async {
    final s1 = service();
    await s1.loadSettings();
    await s1.setChannelNotifyMode(
      devicePrefix: prefixA,
      pskHex: pskX,
      channelName: 'Test',
      mode: ChannelNotifyMode.mentionsOnly,
    );

    // New service instance, same backing prefs = an app restart.
    final s2 = service();
    await s2.loadSettings();
    expect(
      s2.channelNotifyMode(devicePrefix: prefixA, pskHex: pskX),
      ChannelNotifyMode.mentionsOnly,
    );
  });

  test('nested notify map round-trips through JSON', () {
    final original = AppSettings(
      channelNotifyModesByRadio: {
        prefixA: {pskX: ChannelNotifyMode.off},
        prefixB: {pskPublic: ChannelNotifyMode.mentionsOnly},
      },
    );
    final restored = AppSettings.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(
      restored.channelNotifyModesByRadio[prefixA]?[pskX],
      ChannelNotifyMode.off,
    );
    expect(
      restored.channelNotifyModesByRadio[prefixB]?[pskPublic],
      ChannelNotifyMode.mentionsOnly,
    );
  });

  test(
    'legacy flat map (psk- and index-keyed) migrates into the first radio',
    () async {
      // Seed the pre-#839 shape: a global flat map with a psk-keyed and an
      // index-keyed entry, no nested map, not yet migrated.
      final legacy = AppSettings(
        channelNotifyModes: {
          'psk_$pskX': ChannelNotifyMode.mentionsOnly,
          '2': ChannelNotifyMode.off, // resolvable index entry
        },
      );
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(legacy.toJson()),
      });
      PrefsManager.reset();
      await PrefsManager.initialize();

      final s = service();
      await s.loadSettings();

      // First radio connects and its channels are known: migrate into prefixA.
      await s.migrateLegacyChannelNotify(
        devicePrefix: prefixA,
        pskByChannelIndex: {2: pskPublic},
        pskByChannelName: const {},
      );

      expect(
        s.channelNotifyMode(devicePrefix: prefixA, pskHex: pskX),
        ChannelNotifyMode.mentionsOnly, // from the psk_ entry
      );
      expect(
        s.channelNotifyMode(devicePrefix: prefixA, pskHex: pskPublic),
        ChannelNotifyMode.off, // index '2' resolved to pskPublic
      );

      // A second radio starts clean: the legacy state is not re-applied.
      await s.migrateLegacyChannelNotify(
        devicePrefix: prefixB,
        pskByChannelIndex: {2: pskPublic},
        pskByChannelName: const {},
      );
      expect(
        s.settings.channelNotifyModesByRadio[prefixB] ?? const {},
        isEmpty,
      );
    },
  );

  test(
    'legacy name-keyed mute set migrates to Off on its resolved PSK',
    () async {
      final legacy = AppSettings(mutedChannels: {'Public'});
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode(legacy.toJson()),
      });
      PrefsManager.reset();
      await PrefsManager.initialize();

      final s = service();
      await s.loadSettings();
      await s.migrateLegacyChannelNotify(
        devicePrefix: prefixA,
        pskByChannelIndex: const {},
        pskByChannelName: {'Public': pskPublic},
      );

      expect(
        s.channelNotifyMode(devicePrefix: prefixA, pskHex: pskPublic),
        ChannelNotifyMode.off,
      );
    },
  );
}
