import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/pocketmesh_reaction.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';

class _Msg {
  final int timestampSecs;
  final String senderName;
  final String text;
  Map<String, int> reactions = {};
  Map<String, List<String>> reactionSenders = {};

  _Msg(this.timestampSecs, this.senderName, this.text);
}

/// Runs applyReaction over [messages] and reports the match plus the resulting
/// count and sender maps of whichever message was updated.
({
  bool matched,
  Map<String, int>? reactions,
  Map<String, List<String>>? senders,
})
_apply(List<_Msg> messages, ReactionInfo info, {String reactingSender = 'R'}) {
  Map<String, int>? updatedReactions;
  Map<String, List<String>>? updatedSenders;
  final matched = ReactionHelper.applyReaction<_Msg>(
    messages: messages,
    reactionInfo: info,
    reactingSender: reactingSender,
    getTimestampSecs: (m) => m.timestampSecs,
    getSenderName: (m) => m.senderName,
    getMessageText: (m) => m.text,
    getReactions: (m) => m.reactions,
    getReactionSenders: (m) => m.reactionSenders,
    shouldSkip: (_) => false,
    updateMessage: (i, reactions, senders) {
      messages[i].reactions = reactions;
      messages[i].reactionSenders = senders;
      updatedReactions = reactions;
      updatedSenders = senders;
    },
  );
  return (
    matched: matched,
    reactions: updatedReactions,
    senders: updatedSenders,
  );
}

void main() {
  // The live capture from GH #378.
  const capturedText =
      "It's a hash from MeshCore One for emojis. "
      'Looking at how to render better.';
  const capturedTs = 1784871761;
  const capturedSender = 'Strycher WM\u{1F6F0}\u{FE0F}';
  const capturedHash = 'dyps6yf0';

  group('applyReaction dialect dispatch', () {
    test('a PocketMesh reaction matches by the PocketMesh hash', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      final result = _apply(messages, info);

      expect(result.matched, isTrue);
      expect(result.reactions, {'\u{1F44D}': 1});
    });

    test('the sender must match exactly, emoji and all', () {
      final messages = [
        _Msg(capturedTs, 'Strycher WM', capturedText), // no satellite emoji
      ];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      expect(_apply(messages, info).matched, isFalse);
    });

    test('the direct form matches without a sender', () {
      final messages = [_Msg(capturedTs, 'whoever', capturedText)];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse('\u{1F44D}\n$capturedHash', isDm: true)!,
      );

      expect(_apply(messages, info).matched, isTrue);
    });

    test('reports no match when the target is absent', () {
      final messages = [
        _Msg(capturedTs, capturedSender, 'a different message'),
      ];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      expect(_apply(messages, info).matched, isFalse);
    });

    test('the Offband dialect still uses the Offband hash, unchanged', () {
      final messages = [_Msg(1234567890, 'Alice', 'Hello world!')];
      final hash = ReactionHelper.computeReactionHash(
        1234567890,
        'Alice',
        'Hello world!',
      );
      final info = ReactionHelper.parseReaction(
        'r:$hash:${ReactionHelper.emojiToIndex('\u{1F389}')}',
      );

      expect(info, isNotNull);
      expect(info!.dialect, ReactionDialect.offband);

      final result = _apply(messages, info);
      expect(result.matched, isTrue);
      expect(result.reactions, {'\u{1F389}': 1});
    });

    test('the two dialects do not match each other', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      // The PocketMesh hash fed in as if it were ours must not match.
      final info = ReactionInfo(targetHash: capturedHash, emoji: '\u{1F44D}');

      expect(info.dialect, ReactionDialect.offband);
      expect(_apply(messages, info).matched, isFalse);
    });

    test('two different reactors count as 2 and both names are kept', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      _apply(messages, info, reactingSender: 'Alice');
      final second = _apply(messages, info, reactingSender: 'Bob');

      expect(second.reactions, {'\u{1F44D}': 2});
      expect(second.senders, {
        '\u{1F44D}': ['Alice', 'Bob'],
      });
    });

    test('the same reactor with the same emoji does not double-count', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      final first = _apply(messages, info, reactingSender: 'Alice');
      expect(first.reactions, {'\u{1F44D}': 1});

      // Same reactor again: still matched, but no change to count or senders.
      final again = _apply(messages, info, reactingSender: 'Alice');
      expect(again.matched, isTrue);
      expect(messages.single.reactions, {'\u{1F44D}': 1});
      expect(messages.single.reactionSenders, {
        '\u{1F44D}': ['Alice'],
      });
    });

    test('a pre-#383 count with no sender list is preserved, not reset', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      // Simulate a message loaded from an old store: a count, no sender names.
      messages.single.reactions = {'\u{1F44D}': 3};

      final result = _apply(messages, _pm(capturedSender, capturedHash));

      // The old three are kept and the new reactor adds one.
      expect(result.reactions, {'\u{1F44D}': 4});
      expect(result.senders, {
        '\u{1F44D}': ['R'],
      });
    });
  });
}

ReactionInfo _pm(String sender, String hash) => ReactionInfo.pocketMesh(
  PocketMeshReaction.parse('\u{1F44D}@[$sender]\n$hash', isDm: false)!,
);
