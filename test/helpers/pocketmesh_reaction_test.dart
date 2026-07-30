import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/pocketmesh_reaction.dart';

void main() {
  group('PocketMeshReaction', () {
    group('computeHash', () {
      test('reproduces the hash from the live capture (GH #378)', () {
        // Captured 2026-07-24: a MeshCore One peer reacted to this message and
        // sent the hash below. If this ever fails, our hash input drifted from
        // theirs and every incoming reaction will silently stop matching.
        expect(
          PocketMeshReaction.computeHash(
            "It's a hash from MeshCore One for emojis. "
            'Looking at how to render better.',
            1784871761,
          ),
          'dyps6yf0',
        );
      });

      test('is stable for the same input', () {
        final a = PocketMeshReaction.computeHash('Hello', 1704067200);
        final b = PocketMeshReaction.computeHash('Hello', 1704067200);
        expect(a, b);
        expect(a.length, 8);
      });

      test('the timestamp is part of the hash', () {
        expect(
          PocketMeshReaction.computeHash('Hello', 1704067200),
          isNot(PocketMeshReaction.computeHash('Hello', 1704067201)),
        );
      });

      test('handles a timestamp past the 32-bit signed boundary', () {
        // 2^31 + 1. A signed 32-bit shift on the web target would misencode it.
        final hash = PocketMeshReaction.computeHash('Hello', 2147483649);
        expect(hash.length, 8);
        expect(hash, isNot(PocketMeshReaction.computeHash('Hello', 1)));
      });

      test('hashes the body, not the sender-prefixed wire text', () {
        const body = 'Test';
        expect(
          PocketMeshReaction.computeHash(body, 1784871761),
          isNot(PocketMeshReaction.computeHash('Someone: $body', 1784871761)),
        );
      });
    });

    group('parse, channel form', () {
      test('parses the exact payload from the live capture', () {
        final parsed = PocketMeshReaction.parse(
          '\u{1F44D}@[Strycher WM\u{1F6F0}\u{FE0F}]\ndyps6yf0',
          isDm: false,
        );

        expect(parsed, isNotNull);
        expect(parsed!.emoji, '\u{1F44D}');
        expect(parsed.targetSenderName, 'Strycher WM\u{1F6F0}\u{FE0F}');
        expect(parsed.targetHash, 'dyps6yf0');
      });

      test('normalises an uppercase hash', () {
        final parsed = PocketMeshReaction.parse(
          '\u{1F44D}@[Node]\nDYPS6YF0',
          isDm: false,
        );
        expect(parsed?.targetHash, 'dyps6yf0');
      });

      test('rejects a missing sender block', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}\ndyps6yf0', isDm: false),
          isNull,
        );
      });

      test('rejects an unterminated sender block', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}@[Node\ndyps6yf0', isDm: false),
          isNull,
        );
      });

      test('rejects an empty sender', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}@[]\ndyps6yf0', isDm: false),
          isNull,
        );
      });
    });

    group('parse, direct form', () {
      test('parses emoji and hash', () {
        final parsed = PocketMeshReaction.parse(
          '\u{1F44D}\ndyps6yf0',
          isDm: true,
        );

        expect(parsed, isNotNull);
        expect(parsed!.emoji, '\u{1F44D}');
        expect(parsed.targetSenderName, isNull);
        expect(parsed.targetHash, 'dyps6yf0');
      });

      test('rejects the channel form', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}@[Node]\ndyps6yf0', isDm: true),
          isNull,
        );
      });
    });

    group('parse rejects ordinary messages', () {
      test('no newline', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}dyps6yf0', isDm: true),
          isNull,
        );
      });

      test('tail is not 8 characters', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}\ndyps6yf', isDm: true),
          isNull,
        );
        expect(
          PocketMeshReaction.parse('\u{1F44D}\ndyps6yf00', isDm: true),
          isNull,
        );
      });

      test('tail holds a character outside the alphabet', () {
        expect(
          PocketMeshReaction.parse('\u{1F44D}\ndypsuyf0', isDm: true),
          isNull,
        );
      });

      test('nothing before the newline', () {
        expect(PocketMeshReaction.parse('\ndyps6yf0', isDm: true), isNull);
      });

      test('a sentence starting with an arrow is not a reaction', () {
        // Arrows carry the Unicode Emoji property but are ordinary punctuation.
        // A live capture from this mesh had U+2192 mid-sentence in a normal
        // channel message, so the range is excluded outright.
        expect(
          PocketMeshReaction.parse(
            '\u{2190} Turn left at the fork\ndyps6yf0',
            isDm: true,
          ),
          isNull,
        );
        expect(
          PocketMeshReaction.parse('\u{2192}\ndyps6yf0', isDm: true),
          isNull,
        );
      });

      test('a long run of text after a real emoji is not a reaction', () {
        // The swallow risk the rune cap exists for: without it the whole body
        // would become the reaction "emoji".
        expect(
          PocketMeshReaction.parse(
            '\u{1F44D} thanks, that fixed it for me\ndyps6yf0',
            isDm: true,
          ),
          isNull,
        );
      });

      test('accepts a multi-rune emoji sequence', () {
        // Skin tone modifier, then a ZWJ family sequence.
        expect(
          PocketMeshReaction.parse('\u{1F44D}\u{1F3FD}\ndyps6yf0', isDm: true),
          isNotNull,
        );
        expect(
          PocketMeshReaction.parse(
            '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\ndyps6yf0',
            isDm: true,
          ),
          isNotNull,
        );
      });

      test('the leading character is not an emoji', () {
        // The realistic false positive: a two-line message whose last line
        // happens to be eight Crockford characters.
        expect(
          PocketMeshReaction.parse('see below\ndyps6yf0', isDm: true),
          isNull,
        );
        expect(PocketMeshReaction.parse('A\ndyps6yf0', isDm: true), isNull);
      });

      test('our own reaction format is not mistaken for theirs', () {
        expect(PocketMeshReaction.parse('r:3f2a:05', isDm: true), isNull);
      });

      test('accepts the emoji the picker offers as quick reactions', () {
        for (final emoji in [
          '\u{1F44D}',
          '\u{2764}\u{FE0F}',
          '\u{1F602}',
          '\u{1F389}',
          '\u{1F44F}',
          '\u{1F525}',
        ]) {
          expect(
            PocketMeshReaction.parse('$emoji\ndyps6yf0', isDm: true),
            isNotNull,
            reason: 'should accept $emoji',
          );
        }
      });
    });
  });
}
