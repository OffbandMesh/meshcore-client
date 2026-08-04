import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/storage/block_store.dart';

/// In-memory, scope-aware stand-in so the service can be exercised without
/// SharedPreferences. Keys/names are stored per device scope (#471).
class _FakeBlockStore implements BlockStore {
  final Map<String, Set<String>> _keys = {};
  final Map<String, Map<String, int>> _names = {};
  bool legacyDropped = false;

  @override
  String publicKeyHex = '';

  @override
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  @override
  Future<void> dropLegacyGlobal() async => legacyDropped = true;

  Set<String> keysFor(String scope) => {...?_keys[scope]};

  @override
  Future<Set<String>> loadKeys() async =>
      publicKeyHex.isEmpty ? {} : {...?_keys[publicKeyHex]};

  @override
  Future<void> saveKeys(Set<String> value) async {
    if (publicKeyHex.isEmpty) return;
    _keys[publicKeyHex] = {...value};
  }

  @override
  Future<Map<String, int>> loadNames() async =>
      publicKeyHex.isEmpty ? {} : {...?_names[publicKeyHex]};

  @override
  Future<void> saveNames(Map<String, int> value) async {
    if (publicKeyHex.isEmpty) return;
    _names[publicKeyHex] = {...value};
  }
}

void main() {
  // Radios (their own keys double as the per-radio scope + self key).
  const radioA = 'a1a1a1a1a1a1a1a1';
  const radioB = 'b2b2b2b2b2b2b2b2';
  // Contacts to block.
  const bob = '99ff88ee77dd66cc';
  const cara = '4444555566667777';

  late _FakeBlockStore store;
  late BlockService service;
  late List<({String key, bool blocked})> pushes;

  setUp(() {
    store = _FakeBlockStore();
    service = BlockService(store: store);
    pushes = [];
    service.firmwareSync = (key, blocked) =>
        pushes.add((key: key, blocked: blocked));
  });

  group('self-block guard (#250)', () {
    test('block() refuses the connected radio\'s own key', () async {
      await service.loadForDevice(radioA);
      pushes.clear();

      await service.block(radioA);

      expect(service.isBlocked(radioA), isFalse);
      expect(store.keysFor('a1a1a1a1a1'), isNot(contains(radioA)));
      expect(pushes, isEmpty);
    });

    test('block() still blocks a normal contact', () async {
      await service.loadForDevice(radioA);

      await service.block(bob);

      expect(service.isBlocked(bob), isTrue);
      expect(pushes, contains((key: bob, blocked: true)));
    });

    test('importKeys() skips the self key from the radio dump', () async {
      await service.loadForDevice(radioA);

      await service.importKeys([radioA, bob]);

      expect(service.isBlocked(radioA), isFalse);
      expect(service.isBlocked(bob), isTrue);
    });

    test(
      'loadForDevice heals a stale self-block already in the store',
      () async {
        // Radio A's stored list contains A's own key (pre-guard / stale).
        store.saveKeysForTest('a1a1a1a1a1', {radioA, bob});

        await service.loadForDevice(radioA);

        expect(service.isBlocked(radioA), isFalse, reason: 'self healed');
        expect(service.isBlocked(bob), isTrue);
        expect(pushes, contains((key: radioA, blocked: false)));
      },
    );

    test('maybePromote() will not promote a name into a self-block', () async {
      await service.loadForDevice(radioA);
      await service.blockName('me');
      pushes.clear();

      await service.maybePromote('me', radioA);

      expect(service.isBlocked(radioA), isFalse);
      expect(service.isNameBlocked('me'), isFalse);
      expect(pushes, isEmpty);
    });
  });

  group('per-radio isolation + drop-and-start-fresh (#471)', () {
    test('a block on radio A does not appear on radio B', () async {
      await service.loadForDevice(radioA);
      await service.block(bob);
      expect(service.isBlocked(bob), isTrue);

      await service.loadForDevice(radioB);
      expect(
        service.isBlocked(bob),
        isFalse,
        reason: 'radio B has its own list',
      );

      await service.block(cara);
      expect(service.isBlocked(cara), isTrue);
      expect(service.isBlocked(bob), isFalse);

      // Back to A: A still has bob, not cara.
      await service.loadForDevice(radioA);
      expect(service.isBlocked(bob), isTrue);
      expect(service.isBlocked(cara), isFalse);
    });

    test('clearing a radio stays cleared across a reconnect', () async {
      await service.loadForDevice(radioA);
      await service.block(bob);
      await service.unblock(bob);
      expect(service.isBlocked(bob), isFalse);
      pushes.clear(); // ignore the legitimate ADD/REMOVE above

      // Connect another radio, then come back to A. Nothing re-seeds bob.
      await service.loadForDevice(radioB);
      await service.loadForDevice(radioA);
      expect(
        service.isBlocked(bob),
        isFalse,
        reason: 'no global list to re-push the unblocked key',
      );
      expect(
        pushes.where((p) => p.key == bob && p.blocked),
        isEmpty,
        reason: 'bob is never re-ADDed to the radio',
      );
    });

    test('load() drops the legacy global list and starts empty', () async {
      await service.load();
      expect(store.legacyDropped, isTrue);
      expect(service.blockedKeys, isEmpty);
    });

    test('loadForDevice also drops the legacy global list', () async {
      await service.loadForDevice(radioA);
      expect(store.legacyDropped, isTrue);
    });

    test(
      'concurrent loadForDevice + importKeys does not wipe imports (race)',
      () async {
        // Fire the reload without awaiting, then import from the radio's LIST
        // dump immediately after; the connector does exactly this across two
        // frame handlers. Serialization must order them so neither wipes the
        // other; bob (from the dump) must survive.
        final load = service.loadForDevice(radioA);
        final import = service.importKeys([bob]);
        await Future.wait([load, import]);

        expect(
          service.isBlocked(bob),
          isTrue,
          reason: 'imported key survived the concurrent reload',
        );
        expect(store.keysFor('a1a1a1a1a1'), contains(bob));
      },
    );

    test('disconnect (null device) clears the in-memory set', () async {
      await service.loadForDevice(radioA);
      await service.block(bob);
      expect(service.isBlocked(bob), isTrue);

      await service.loadForDevice(null);
      expect(service.blockedKeys, isEmpty);
      expect(service.isSelf(radioA), isFalse);
    });
  });
}

extension on _FakeBlockStore {
  void saveKeysForTest(String scope, Set<String> keys) => _keys[scope] = keys;
}
