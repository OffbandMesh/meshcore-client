// Epic #815 T C1: per-channel region-scope store.
// Device-key scoped (first 10 hex chars of the device public key), channel -> region name.

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/storage/channel_region_scope_store.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _devA = 'aabbccddee0011223344';
const _devB = 'ffeeddccbb0011223344';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PrefsManager.reset();
    await PrefsManager.initialize();
  });

  ChannelRegionScopeStore storeFor(String deviceKeyHex) {
    final s = ChannelRegionScopeStore();
    s.setPublicKeyHex = deviceKeyHex;
    return s;
  }

  test('set / get / clear round-trip', () async {
    final store = storeFor(_devA);
    expect(await store.scopeFor(0), isNull);
    await store.setScope(0, 'oki');
    expect(await store.scopeFor(0), 'oki');
    await store.clearScope(0);
    expect(await store.scopeFor(0), isNull);
  });

  test('scopes are isolated per device key', () async {
    await storeFor(_devA).setScope(2, 'oki');
    expect(await storeFor(_devB).scopeFor(2), isNull);
    expect(await storeFor(_devA).scopeFor(2), 'oki');
  });

  test('scopes are isolated per channel index', () async {
    final store = storeFor(_devA);
    await store.setScope(1, 'oki');
    expect(await store.scopeFor(3), isNull);
    expect(await store.scopeFor(1), 'oki');
  });

  test('survives a fresh store instance (persisted to prefs)', () async {
    await storeFor(_devA).setScope(5, 'test');
    final reopened = storeFor(_devA);
    expect(await reopened.scopeFor(5), 'test');
  });

  test('with no device key set, reads null and writes are refused', () async {
    final store = ChannelRegionScopeStore();
    await store.setScope(0, 'oki');
    expect(await store.scopeFor(0), isNull);
  });

  group('PSK identity keying (#1256)', () {
    test('scope follows the channel PSK across a slot reshuffle', () async {
      final store = storeFor(_devA);
      final slots = <int, String?>{0: 'pskaaaa', 1: 'pskbbbb'};
      store.channelPskResolver = (i) => slots[i];
      await store.setScope(0, 'oki'); // channel pskaaaa at slot 0

      // A sync reshuffles the slots: pskaaaa moves to slot 1, pskbbbb to slot 0.
      slots[0] = 'pskbbbb';
      slots[1] = 'pskaaaa';

      expect(await store.scopeFor(1), 'oki'); // scope followed pskaaaa
      expect(await store.scopeFor(0), isNull); // pskbbbb has no scope
    });

    test('keys by PSK, not index, when the resolver is set', () async {
      final store = storeFor(_devA);
      store.channelPskResolver = (i) => 'pskzzzz';
      await store.setScope(0, 'day');
      // A different slot index resolving to the same PSK sees the same scope.
      expect(await store.scopeFor(9), 'day');
    });

    test('adopts a legacy index-keyed scope once the PSK is known', () async {
      // Pre-fix value: written with no resolver, so it lives on the index key.
      await storeFor(_devA).setScope(2, 'cvg');

      final store = storeFor(_devA);
      store.channelPskResolver = (i) => i == 2 ? 'pskcccc' : null;
      expect(await store.scopeFor(2), 'cvg'); // migrated off the index key

      // Migration is sticky: now reachable by PSK even if the slot moves, and
      // the old index key is gone.
      store.channelPskResolver = (i) => i == 5 ? 'pskcccc' : null;
      expect(await store.scopeFor(5), 'cvg');
      expect(await store.scopeFor(2), isNull);
    });
  });
}
