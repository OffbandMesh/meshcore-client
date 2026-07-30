import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/block_service.dart';
import 'package:meshcore_open/storage/block_store.dart';

/// In-memory stand-in so the service can be exercised without SharedPreferences.
class _FakeBlockStore implements BlockStore {
  Set<String> keys = {};
  Map<String, int> names = {};

  @override
  Future<Set<String>> loadKeys() async => {...keys};

  @override
  Future<void> saveKeys(Set<String> value) async => keys = {...value};

  @override
  Future<Map<String, int>> loadNames() async => {...names};

  @override
  Future<void> saveNames(Map<String, int> value) async => names = {...value};
}

void main() {
  const selfKey = 'aa11bb22cc33dd44';
  const otherKey = '99ff88ee77dd66cc';

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
    test('block() refuses the self key and pushes nothing', () async {
      await service.setSelfKey(selfKey);
      pushes.clear();

      await service.block(selfKey);

      expect(service.isBlocked(selfKey), isFalse);
      expect(store.keys, isNot(contains(selfKey)));
      expect(pushes, isEmpty);
    });

    test('block() still blocks a normal key', () async {
      await service.setSelfKey(selfKey);

      await service.block(otherKey);

      expect(service.isBlocked(otherKey), isTrue);
      expect(pushes, contains((key: otherKey, blocked: true)));
    });

    test('importKeys() skips self so the radio cannot re-import it', () async {
      await service.setSelfKey(selfKey);

      await service.importKeys([selfKey, otherKey]);

      expect(service.isBlocked(selfKey), isFalse);
      expect(service.isBlocked(otherKey), isTrue);
    });

    test('setSelfKey() heals an existing self-block and sends REMOVE', () async {
      // Blocked before the guard existed (or pulled in before self-info landed).
      await service.block(selfKey);
      expect(service.isBlocked(selfKey), isTrue);
      pushes.clear();

      await service.setSelfKey(selfKey);

      expect(service.isBlocked(selfKey), isFalse);
      expect(store.keys, isNot(contains(selfKey)));
      expect(pushes, contains((key: selfKey, blocked: false)));
    });

    test('maybePromote() will not promote a name into a self-block', () async {
      await service.setSelfKey(selfKey);
      await service.blockName('me');
      pushes.clear();

      await service.maybePromote('me', selfKey);

      expect(service.isBlocked(selfKey), isFalse);
      expect(service.isNameBlocked('me'), isFalse);
      expect(pushes, isEmpty);
    });

    test('heals a self-block even when the self key is unchanged', () async {
      await service.setSelfKey(selfKey);

      // Stale persisted state reloaded while the self key is already known,
      // load() does not filter, so this lands a self-block behind the guards.
      store.keys = {selfKey, otherKey};
      await service.load();
      expect(service.isBlocked(selfKey), isTrue);
      pushes.clear();

      // Same key as before, so an unchanged-key early return would strand it.
      await service.setSelfKey(selfKey);

      expect(service.isBlocked(selfKey), isFalse);
      expect(
        service.isBlocked(otherKey),
        isTrue,
        reason: 'only self is healed',
      );
      expect(pushes, contains((key: selfKey, blocked: false)));
    });

    test('repeat setSelfKey with nothing to heal pushes nothing', () async {
      await service.setSelfKey(selfKey);
      pushes.clear();

      await service.setSelfKey(selfKey);

      expect(pushes, isEmpty);
      expect(service.isSelf(selfKey), isTrue);
    });

    test('state is consistent synchronously when not awaited', () async {
      await service.setSelfKey(selfKey);
      await service.setSelfKey(null);
      await service.block(selfKey);

      // Fire-and-forget, as the connector does via unawaited().
      final future = service.setSelfKey(selfKey);

      expect(service.isSelf(selfKey), isTrue);
      expect(service.isBlocked(selfKey), isFalse);
      await future;
      expect(store.keys, isNot(contains(selfKey)));
    });

    test('isSelf() is false when no self key is known', () {
      expect(service.isSelf(selfKey), isFalse);
    });

    test('clearing the self key stops treating the old key as self', () async {
      await service.setSelfKey(selfKey);
      await service.setSelfKey(null);

      expect(service.isSelf(selfKey), isFalse);

      await service.block(selfKey);
      expect(service.isBlocked(selfKey), isTrue);
    });
  });
}
