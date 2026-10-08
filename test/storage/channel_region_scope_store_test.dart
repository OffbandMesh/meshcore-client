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
}
