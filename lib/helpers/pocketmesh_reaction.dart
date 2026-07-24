import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'crockford_base32.dart';

/// A reaction in the PocketMesh / MeshCore One wire format.
///
/// Channel form: `{emoji}@[{targetSenderName}]\n{hash}`
/// Direct form:  `{emoji}\n{hash}`
///
/// The hash identifies the target message as sha256 over the target's body
/// text (UTF-8) followed by its sender-claimed timestamp as a little-endian
/// uint32 of epoch seconds, truncated to the first 5 bytes and encoded as 8
/// Crockford Base32 characters. The channel `SenderName: ` prefix is NOT part
/// of the hashed text, which is why the sender travels in `@[...]` instead.
///
/// Confirmed against a live capture from a MeshCore One peer, see GH #378.
/// Receive-only: Offband still sends its own `r:hhhh:ii` format (GH #379).
class PocketMeshReaction {
  final String emoji;

  /// The target message's sender, present in the channel form only. In a direct
  /// conversation the sender is implicit.
  final String? targetSenderName;

  /// 8 characters, lowercase canonical form.
  final String targetHash;

  const PocketMeshReaction({
    required this.emoji,
    required this.targetHash,
    this.targetSenderName,
  });

  static String computeHash(String bodyText, int timestampSeconds) {
    final body = utf8.encode(bodyText);
    final input = Uint8List(body.length + 4);
    input.setRange(0, body.length, body);
    // Division rather than shifts: `>>` is signed 32-bit on the web target and
    // would misencode any timestamp past 2038.
    final seconds = timestampSeconds % 4294967296;
    input[body.length] = seconds % 256;
    input[body.length + 1] = (seconds ~/ 256) % 256;
    input[body.length + 2] = (seconds ~/ 65536) % 256;
    input[body.length + 3] = (seconds ~/ 16777216) % 256;
    return CrockfordBase32.encode5(sha256.convert(input).bytes.sublist(0, 5));
  }

  /// Parse [text] as a reaction, or null if it is an ordinary message.
  ///
  /// Mirrors the reference parser: the last line must be exactly 8 valid
  /// Crockford Base32 characters, and the part before it must start with an
  /// emoji. Both checks matter, since anything accepted here is swallowed
  /// instead of being shown as a message.
  static PocketMeshReaction? parse(String text, {required bool isDm}) {
    final newline = text.lastIndexOf('\n');
    if (newline < 0) return null;

    final hash = CrockfordBase32.normalize8(text.substring(newline + 1));
    if (hash == null) return null;

    final head = text.substring(0, newline);

    if (isDm) {
      if (head.contains('@[')) return null;
      return _build(emoji: head, sender: null, hash: hash);
    }

    final bracket = head.indexOf('@[');
    if (bracket < 0) return null;
    final afterBracket = head.substring(bracket + 2);
    if (!afterBracket.endsWith(']')) return null;
    final sender = afterBracket.substring(0, afterBracket.length - 1);
    if (sender.isEmpty) return null;

    return _build(
      emoji: head.substring(0, bracket),
      sender: sender,
      hash: hash,
    );
  }

  static PocketMeshReaction? _build({
    required String emoji,
    required String? sender,
    required String hash,
  }) {
    if (!_isReactionEmoji(emoji)) return null;
    return PocketMeshReaction(
      emoji: emoji,
      targetSenderName: sender,
      targetHash: hash,
    );
  }

  /// A reaction is one emoji, possibly with a variation selector, a skin-tone
  /// modifier or ZWJ joins. Eight runes is well clear of the longest such
  /// sequence and nowhere near a sentence.
  ///
  /// This cap is the guard that matters: without it, any multi-line message
  /// starting with a symbol and ending in eight Crockford characters would be
  /// swallowed whole and shown as the reaction "emoji".
  static const int _maxEmojiRunes = 8;

  /// Deliberately conservative: a missed emoji only means the reaction renders
  /// as text, which is the behaviour we have today, while a false positive
  /// would swallow a real message.
  ///
  /// Arrows (U+2190-U+21FF, U+2934-U+2935) are excluded on purpose even though
  /// they carry the Unicode Emoji property. They are ordinary punctuation in
  /// prose, and a live capture from this mesh contained U+2192 mid-sentence in
  /// a normal channel message.
  static const List<List<int>> _emojiRanges = [
    [0x1F000, 0x1FAFF],
    [0x2600, 0x27BF],
    [0x2B00, 0x2BFF],
    [0x3030, 0x3030],
    [0x303D, 0x303D],
    [0x3297, 0x3299],
  ];

  static bool _isReactionEmoji(String text) {
    final runes = text.runes;
    if (runes.isEmpty || runes.length > _maxEmojiRunes) return false;
    final first = runes.first;
    for (final range in _emojiRanges) {
      if (first >= range[0] && first <= range[1]) return true;
    }
    return false;
  }
}
