import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/pending_reactions.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';

ReactionInfo _info(String hash) =>
    ReactionInfo(targetHash: hash, emoji: '\u{1F44D}');

void main() {
  group('PendingReactions', () {
    final now = DateTime.utc(2026, 7, 24, 1, 43);

    test('holds a reaction whose target has not arrived', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);
      expect(pending.length, 1);
    });

    test('applies a held reaction once the target lands', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);

      final applied = <String>[];
      final reactors = <String>[];
      pending.retry('channel:0', (info, reactingSender) {
        applied.add(info.targetHash);
        reactors.add(reactingSender);
        return true;
      }, now.add(const Duration(seconds: 5)));

      expect(applied, ['dyps6yf0']);
      expect(reactors, [
        'Node',
      ], reason: 'the queued reactor is passed through');
      expect(pending.length, 0);
    });

    test('keeps a reaction that still has no target', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);

      pending.retry(
        'channel:0',
        (_, _) => false,
        now.add(const Duration(seconds: 5)),
      );

      expect(pending.length, 1);
    });

    test('does not leak across scopes', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);

      var called = false;
      pending.retry('channel:1', (_, _) {
        called = true;
        return true;
      }, now);

      expect(called, isFalse);
      expect(pending.length, 1);
    });

    test('drops a reaction that outlives the TTL', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);

      pending.expire(now.add(PendingReactions.ttl));

      expect(pending.length, 0);
    });

    test('keeps a reaction that is still inside the TTL', () {
      final pending = PendingReactions();
      pending.add('channel:0', _info('dyps6yf0'), 'Node', now);

      pending.expire(
        now.add(PendingReactions.ttl - const Duration(seconds: 1)),
      );

      expect(pending.length, 1);
    });

    test('caps the queue and evicts the oldest first', () {
      final pending = PendingReactions();
      for (var i = 0; i <= PendingReactions.maxEntries; i++) {
        pending.add(
          'channel:0',
          _info(i.toString().padLeft(8, '0')),
          'Node',
          now.add(Duration(seconds: i)),
        );
      }

      expect(pending.length, PendingReactions.maxEntries);

      final seen = <String>[];
      pending.retry('channel:0', (info, _) {
        seen.add(info.targetHash);
        return true;
      }, now.add(const Duration(minutes: 1)));

      expect(seen, isNot(contains('00000000')), reason: 'oldest was evicted');
      expect(seen.length, PendingReactions.maxEntries);
    });
  });
}
