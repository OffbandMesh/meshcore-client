import '../widgets/emoji_picker.dart';
import 'pocketmesh_reaction.dart';

/// Which client's reaction format a [ReactionInfo] came from. The two use
/// different target hashes, so matching has to know which one it holds.
enum ReactionDialect {
  /// Offband's own `r:hhhh:ii`.
  offband,

  /// PocketMesh / MeshCore One, `{emoji}@[{sender}]\n{hash}`. Receive-only.
  pocketMesh,
}

class ReactionInfo {
  final String targetHash;
  final String emoji;
  final ReactionDialect dialect;

  /// The target message's sender, carried by the PocketMesh channel form only.
  /// When set, a candidate must match it as well as the hash.
  final String? targetSenderName;

  ReactionInfo({
    required this.targetHash,
    required this.emoji,
    this.dialect = ReactionDialect.offband,
    this.targetSenderName,
  });

  ReactionInfo.pocketMesh(PocketMeshReaction reaction)
    : targetHash = reaction.targetHash,
      emoji = reaction.emoji,
      dialect = ReactionDialect.pocketMesh,
      targetSenderName = reaction.targetSenderName;
}

class ReactionHelper {
  /// Deserialize the additive `reactionSenders` map from stored JSON (#383).
  ///
  /// Returns an empty map for records written before the field existed, so an
  /// old store loads cleanly (its counts still come from the `reactions` key).
  /// Malformed or wrongly-typed entries are skipped rather than thrown, because
  /// a single bad entry must never fail the whole message-list load.
  static Map<String, List<String>> reactionSendersFromJson(Object? raw) {
    if (raw is! Map) return {};
    final result = <String, List<String>>{};
    raw.forEach((key, value) {
      if (key is String && value is List) {
        result[key] = value.whereType<String>().toList();
      }
    });
    return result;
  }

  /// Apply a reaction to a list of messages by matching the reaction hash.
  ///
  /// [messages] - the message list to search
  /// [reactionInfo] - the parsed reaction
  /// [getTimestampSecs] - extract timestamp seconds from a message
  /// [getSenderName] - extract sender name for hash (null for 1:1 implicit)
  /// [getMessageText] - extract message text
  /// [getReactions] - extract current reactions map
  /// [getReactionSenders] - extract current emoji->reactor-names map (#383)
  /// [reactingSender] - the name of whoever sent this reaction
  /// [shouldSkip] - filter function to skip messages (e.g., skip outgoing for incoming reactions)
  /// [updateMessage] - callback to update the message at index with the new
  ///   count map and the new sender map
  ///
  /// Returns whether a match was found.
  ///
  /// [reactionSenders] is the persistent per-reactor record. A given reactor is
  /// counted once per emoji: if their name is already in the list, the reaction
  /// is a no-op on both maps (this survives restart, unlike the connector's
  /// in-memory dedup set). Counts recorded before #383 have no sender list, so
  /// the count is still incremented from its stored value rather than being
  /// recomputed from the (partial) sender list, which would lose those.
  static bool applyReaction<T>({
    required List<T> messages,
    required ReactionInfo reactionInfo,
    required String reactingSender,
    required int Function(T) getTimestampSecs,
    required String? Function(T) getSenderName,
    required String Function(T) getMessageText,
    required Map<String, int> Function(T) getReactions,
    required Map<String, List<String>> Function(T) getReactionSenders,
    required bool Function(T) shouldSkip,
    required void Function(
      int index,
      Map<String, int> newReactions,
      Map<String, List<String>> newSenders,
    )
    updateMessage,
  }) {
    final targetHash = reactionInfo.targetHash;
    final targetSender = reactionInfo.targetSenderName;
    final emoji = reactionInfo.emoji;
    for (int i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (shouldSkip(msg)) continue;

      // Exact compare, no normalising: a node name can carry emoji and
      // variation selectors (a live capture used "Strycher WM\u{1F6F0}\u{FE0F}")
      // and any folding would break the match.
      if (targetSender != null && getSenderName(msg) != targetSender) continue;

      final msgHash = switch (reactionInfo.dialect) {
        ReactionDialect.offband => computeReactionHash(
          getTimestampSecs(msg),
          getSenderName(msg),
          getMessageText(msg),
        ),
        ReactionDialect.pocketMesh => PocketMeshReaction.computeHash(
          getMessageText(msg),
          getTimestampSecs(msg),
        ),
      };
      if (msgHash == targetHash) {
        final senders = <String, List<String>>{
          for (final e in getReactionSenders(msg).entries)
            e.key: List<String>.from(e.value),
        };
        final list = senders.putIfAbsent(emoji, () => <String>[]);
        if (list.contains(reactingSender)) {
          // Already recorded this reactor for this emoji; matched, no change.
          return true;
        }
        list.add(reactingSender);

        final currentReactions = Map<String, int>.from(getReactions(msg));
        currentReactions[emoji] = (currentReactions[emoji] ?? 0) + 1;
        updateMessage(i, currentReactions, senders);
        return true;
      }
    }
    return false;
  }

  static List<String>? _cachedEmojis;

  /// Combined list of all reaction emojis in fixed order.
  /// Order must stay stable for index compatibility.
  static List<String> get reactionEmojis {
    return _cachedEmojis ??= [
      ...EmojiPicker.quickEmojis,
      ...EmojiPicker.smileys,
      ...EmojiPicker.gestures,
      ...EmojiPicker.hearts,
      ...EmojiPicker.objects,
    ];
  }

  /// Convert emoji to 2-char hex index. Returns null if emoji not in list.
  static String? emojiToIndex(String emoji) {
    final idx = reactionEmojis.indexOf(emoji);
    if (idx < 0) return null;
    return idx.toRadixString(16).padLeft(2, '0');
  }

  /// Convert 2-char hex index to emoji. Returns null if invalid index.
  static String? indexToEmoji(String hexIndex) {
    final idx = int.tryParse(hexIndex, radix: 16);
    if (idx == null || idx < 0 || idx >= reactionEmojis.length) return null;
    return reactionEmojis[idx];
  }

  /// Compute a 4-char hex hash for a message reaction.
  /// Hash input: timestampSeconds + [senderName] + first 5 chars of text
  /// For 1:1 chats, senderName can be null (sender is implicit).
  static String computeReactionHash(
    int timestampSeconds,
    String? senderName,
    String text,
  ) {
    final first5 = text.length >= 5 ? text.substring(0, 5) : text;
    final input = senderName != null
        ? '$timestampSeconds$senderName$first5'
        : '$timestampSeconds$first5';
    // Use hashCode and take lower 16 bits, format as 4 hex chars
    final hash = input.hashCode & 0xFFFF;
    return hash.toRadixString(16).padLeft(4, '0');
  }

  /// Parse reaction format: r:HASH:INDEX (where INDEX is 2-char hex emoji index)
  /// Returns null if text is not a valid reaction format
  static ReactionInfo? parseReaction(String text) {
    final regex = RegExp(r'^r:([0-9a-f]{4}):([0-9a-f]{2})$');
    final match = regex.firstMatch(text);
    if (match == null) return null;

    final emoji = indexToEmoji(match.group(2)!);
    if (emoji == null) return null;

    return ReactionInfo(targetHash: match.group(1)!, emoji: emoji);
  }

  /// Encode a reaction message that parseReaction() can parse.
  static String encodeReaction(String hash, String emojiIndex) {
    return 'r:$hash:$emojiIndex';
  }
}
