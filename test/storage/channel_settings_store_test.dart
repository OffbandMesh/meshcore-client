// Cyr2Lat per-channel settings, keyed by channel PSK identity (#1257).

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/channel_settings_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _devA = 'aabbccddee0011223344';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  ChannelSettingsStore storeFor(String deviceKeyHex) {
    final s = ChannelSettingsStore();
    s.setPublicKeyHex = deviceKeyHex;
    return s;
  }

  test(
    'enabled + profile round-trip without a resolver (index fallback)',
    () async {
      final store = storeFor(_devA);
      expect(await store.loadCyr2LatEnabled(0), isFalse);
      await store.saveCyr2LatEnabled(0, true);
      expect(await store.loadCyr2LatEnabled(0), isTrue);
      await store.saveCyr2LatProfileId(0, 'ru');
      expect(await store.loadCyr2LatProfileId(0), 'ru');
    },
  );

  group('PSK identity keying (#1257)', () {
    test('enabled follows the channel PSK across a slot reshuffle', () async {
      final store = storeFor(_devA);
      final slots = <int, String?>{0: 'pskaaaa', 1: 'pskbbbb'};
      store.channelPskResolver = (i) => slots[i];
      await store.saveCyr2LatEnabled(0, true); // channel pskaaaa at slot 0

      slots[0] = 'pskbbbb';
      slots[1] = 'pskaaaa';

      expect(await store.loadCyr2LatEnabled(1), isTrue); // followed pskaaaa
      expect(await store.loadCyr2LatEnabled(0), isFalse); // pskbbbb unset
    });

    test(
      'profile id follows the channel PSK across a slot reshuffle',
      () async {
        final store = storeFor(_devA);
        final slots = <int, String?>{0: 'pskaaaa', 1: 'pskbbbb'};
        store.channelPskResolver = (i) => slots[i];
        await store.saveCyr2LatProfileId(0, 'ru');

        slots[0] = 'pskbbbb';
        slots[1] = 'pskaaaa';

        expect(await store.loadCyr2LatProfileId(1), 'ru');
        expect(await store.loadCyr2LatProfileId(0), isNull);
      },
    );

    test(
      'adopts a legacy index-keyed enabled flag once the PSK is known',
      () async {
        await storeFor(
          _devA,
        ).saveCyr2LatEnabled(2, true); // index-keyed (no resolver)

        final store = storeFor(_devA);
        store.channelPskResolver = (i) => i == 2 ? 'pskcccc' : null;
        expect(await store.loadCyr2LatEnabled(2), isTrue); // migrated

        store.channelPskResolver = (i) => i == 5 ? 'pskcccc' : null;
        expect(await store.loadCyr2LatEnabled(5), isTrue); // sticky by PSK
        expect(await store.loadCyr2LatEnabled(2), isFalse); // index key gone
      },
    );
  });
}
