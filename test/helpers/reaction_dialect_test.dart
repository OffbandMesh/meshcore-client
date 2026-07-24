import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/pocketmesh_reaction.dart';
import 'package:meshcore_open/helpers/reaction_helper.dart';

class _Msg {
  final int timestampSecs;
  final String senderName;
  final String text;
  Map<String, int> reactions = {};

  _Msg(this.timestampSecs, this.senderName, this.text);
}

/// Runs applyReaction over [messages] and reports the match plus the resulting
/// reaction map of whichever message was updated.
({bool matched, Map<String, int>? reactions}) _apply(
  List<_Msg> messages,
  ReactionInfo info,
) {
  Map<String, int>? updated;
  final matched = ReactionHelper.applyReaction<_Msg>(
    messages: messages,
    reactionInfo: info,
    getTimestampSecs: (m) => m.timestampSecs,
    getSenderName: (m) => m.senderName,
    getMessageText: (m) => m.text,
    getReactions: (m) => m.reactions,
    shouldSkip: (_) => false,
    updateMessage: (i, reactions) {
      messages[i].reactions = reactions;
      updated = reactions;
    },
  );
  return (matched: matched, reactions: updated);
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

    test('counts accumulate for the same emoji', () {
      final messages = [_Msg(capturedTs, capturedSender, capturedText)];
      final info = ReactionInfo.pocketMesh(
        PocketMeshReaction.parse(
          '\u{1F44D}@[$capturedSender]\n$capturedHash',
          isDm: false,
        )!,
      );

      _apply(messages, info);
      final second = _apply(messages, info);

      expect(second.reactions, {'\u{1F44D}': 2});
    });
  });
}
