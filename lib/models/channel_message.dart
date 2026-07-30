import 'dart:typed_data';
import '../connector/meshcore_protocol.dart';
import '../helpers/reaction_helper.dart';
import '../helpers/smaz.dart';
import 'translation_support.dart';
import '../utils/app_logger.dart';

enum ChannelMessageStatus { pending, sent, failed }

class Repeat {
  final Uint8List? repeaterKey;
  final String repeaterName;
  final int tripTimeMs;
  final List<Uint8List>? path;

  Repeat({
    this.repeaterKey,
    required this.repeaterName,
    required this.tripTimeMs,
    this.path,
  });

  String? get repeaterKeyHex =>
      repeaterKey != null ? pubKeyToHex(repeaterKey!) : null;
}

class ChannelMessage {
  static const Object _unset = Object();

  final Uint8List? senderKey;
  final String senderName;
  final String text;
  final String? originalText;
  final String? translatedText;
  final String? translatedLanguageCode;
  final MessageTranslationStatus translationStatus;
  final String? translationModelId;
  final DateTime timestamp;
  final bool isOutgoing;
  final ChannelMessageStatus status;
  final List<Repeat> repeats;
  final int repeatCount;
  final int? pathLength;
  final Uint8List pathBytes;
  final List<Uint8List> pathVariants;
  final int? channelIndex;
  final String messageId;
  final String? packetHash;
  final String? replyToMessageId;
  final String? replyToSenderName;
  final String? replyToText;
  final Map<String, int> reactions;

  /// Emoji to the list of sender names who reacted with it (#383).
  ///
  /// Additive over [reactions]: the count map is still written and read so an
  /// older build degrades to "counts work, names missing" rather than failing
  /// to load. Reactions recorded before this field existed appear in
  /// [reactions] with no matching entry here.
  final Map<String, List<String>> reactionSenders;

  /// Local wall-clock time this message's frame arrived, set at ingest.
  /// Null for outgoing messages and records stored before #285, never
  /// fabricated. [timestamp] is the SENDER's claimed time; this is ours.
  final DateTime? rxTime;

  ChannelMessage({
    this.senderKey,
    required this.senderName,
    required this.text,
    this.originalText,
    this.translatedText,
    this.translatedLanguageCode,
    this.translationStatus = MessageTranslationStatus.none,
    this.translationModelId,
    required this.timestamp,
    required this.isOutgoing,
    this.status = ChannelMessageStatus.pending,
    this.repeats = const [],
    this.repeatCount = 0,
    this.pathLength,
    Uint8List? pathBytes,
    List<Uint8List>? pathVariants,
    this.channelIndex,
    String? messageId,
    this.packetHash,
    this.replyToMessageId,
    this.replyToSenderName,
    this.replyToText,
    Map<String, int>? reactions,
    Map<String, List<String>>? reactionSenders,
    this.rxTime,
  }) : messageId =
           messageId ??
           '${timestamp.millisecondsSinceEpoch}_${senderName.hashCode}_${text.hashCode}',
       reactions = reactions ?? {},
       reactionSenders = reactionSenders ?? {},
       pathBytes = pathBytes ?? Uint8List(0),
       pathVariants = _mergePathVariants(
         pathBytes ?? Uint8List(0),
         pathVariants,
       );

  String? get senderKeyHex =>
      senderKey != null ? pubKeyToHex(senderKey!) : null;

  /// Hop count decoded from the firmware path-length byte (low 6 bits).
  /// The raw byte also packs hash width in its high 2 bits, so the stored
  /// pathLength is NOT the hop count, use this getter for display.
  /// Returns null when unknown; a negative (flood) sentinel is preserved.
  int? get hopCount {
    final pl = pathLength;
    if (pl == null) return null;
    if (pl < 0) return pl;
    return pathHopCount(pl);
  }

  /// Bytes per hop hash, decoded from the path-length byte (high 2 bits -> 1..3).
  int get pathHashSize {
    final pl = pathLength;
    if (pl == null || pl < 0) return 1;
    return pathHashSizeBytes(pl);
  }

  ChannelMessage copyWith({
    ChannelMessageStatus? status,
    List<Repeat>? repeats,
    int? repeatCount,
    int? pathLength,
    Uint8List? pathBytes,
    List<Uint8List>? pathVariants,
    String? packetHash,
    String? replyToMessageId,
    String? replyToSenderName,
    String? replyToText,
    Object? originalText = _unset,
    Object? translatedText = _unset,
    Object? translatedLanguageCode = _unset,
    MessageTranslationStatus? translationStatus,
    Object? translationModelId = _unset,
    Map<String, int>? reactions,
    Map<String, List<String>>? reactionSenders,
    DateTime? rxTime,
  }) {
    return ChannelMessage(
      senderKey: senderKey,
      senderName: senderName,
      text: text,
      originalText: originalText == _unset
          ? this.originalText
          : originalText as String?,
      translatedText: translatedText == _unset
          ? this.translatedText
          : translatedText as String?,
      translatedLanguageCode: translatedLanguageCode == _unset
          ? this.translatedLanguageCode
          : translatedLanguageCode as String?,
      translationStatus: translationStatus ?? this.translationStatus,
      translationModelId: translationModelId == _unset
          ? this.translationModelId
          : translationModelId as String?,
      timestamp: timestamp,
      isOutgoing: isOutgoing,
      status: status ?? this.status,
      repeats: repeats ?? this.repeats,
      repeatCount: repeatCount ?? this.repeatCount,
      pathLength: pathLength ?? this.pathLength,
      pathBytes: pathBytes ?? this.pathBytes,
      pathVariants: pathVariants ?? this.pathVariants,
      channelIndex: channelIndex,
      messageId: messageId,
      packetHash: packetHash ?? this.packetHash,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderName: replyToSenderName ?? this.replyToSenderName,
      replyToText: replyToText ?? this.replyToText,
      reactions: reactions ?? this.reactions,
      reactionSenders: reactionSenders ?? this.reactionSenders,
      rxTime: rxTime ?? this.rxTime,
    );
  }

  static ChannelMessage? fromFrame(Uint8List frame) {
    // CHANNEL_MSG_RECV format varies by version:
    // V3: [0]=code [1]=SNR [2]=rsv1 [3]=rsv2 [4]=channel_idx [5]=path_len [path... optional] [txt_type] [timestamp x4] [text...]
    // Non-V3: [0]=code [1]=channel_idx [2]=path_len [3]=txt_type [4-7]=timestamp [8+]=text
    if (frame.length < 8) return null;
    try {
      final reader = BufferReader(frame);
      final code = reader.readByte();
      if (code != respCodeChannelMsgRecv && code != respCodeChannelMsgRecvV3) {
        return null;
      }

      int pathLen;
      int txtType;
      Uint8List pathBytes = Uint8List(0);
      int channelIdx;
      bool isOutgoing = false;
      if (code == respCodeChannelMsgRecvV3) {
        reader.skipBytes(1); // Skip SNR
        // reserved1 bit0 = outgoing flag: set for a message composed on the
        // device itself, so it renders as sent-by-me (#429 part B). No firmware
        // appends path bytes to this frame, so path_len is metadata only.
        isOutgoing = (reader.readByte() & 0x01) != 0;
        reader.skipBytes(1); // Skip reserved2
        channelIdx = reader.readByte();
        pathLen = reader.readInt8();
        txtType = reader.readByte();
      } else {
        channelIdx = reader.readByte();
        pathLen = reader.readInt8();
        txtType = reader.readByte();
      }
      final timestampRaw = reader.readUInt32LE();

      if (txtType != txtTypePlain) {
        return null;
      }

      final text = reader.readCString();

      // Extract sender name and actual message from "name: msg" format
      String senderName = 'Unknown';
      String actualText = text;

      final colonIndex = text.indexOf(':');
      if (colonIndex > 0 && colonIndex < text.length - 1 && colonIndex < 50) {
        final potentialSender = text.substring(0, colonIndex);
        if (!RegExp(r'[:\[\]]').hasMatch(potentialSender)) {
          senderName = potentialSender;
          final offset =
              (colonIndex + 1 < text.length && text[colonIndex + 1] == ' ')
              ? colonIndex + 2
              : colonIndex + 1;
          actualText = text.substring(offset);
        }
      }

      final decodedText = Smaz.tryDecodePrefixed(actualText) ?? actualText;

      return ChannelMessage(
        senderKey: null,
        senderName: senderName,
        text: decodedText,
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestampRaw * 1000),
        isOutgoing: isOutgoing,
        status: ChannelMessageStatus.sent,
        pathLength: pathLen,
        pathBytes: pathBytes,
        channelIndex: channelIdx,
        rxTime: isOutgoing ? null : DateTime.now(),
      );
    } catch (e) {
      appLogger.error('Error parsing channel message frame: $e');
      // If parsing fails, return null to avoid crashes
      return null;
    }
  }

  static ChannelMessage outgoing(
    String text,
    String senderName,
    int channelIndex, {
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
  }) {
    return ChannelMessage(
      senderKey: null,
      senderName: senderName,
      text: text,
      originalText: originalText,
      translatedLanguageCode: translatedLanguageCode,
      translationModelId: translationModelId,
      timestamp: DateTime.now(),
      isOutgoing: true,
      status: ChannelMessageStatus.pending,
      pathLength: null,
      pathBytes: Uint8List(0),
      pathVariants: const [],
      channelIndex: channelIndex,
    );
  }

  static List<Uint8List> _mergePathVariants(
    Uint8List pathBytes,
    List<Uint8List>? pathVariants,
  ) {
    final merged = <Uint8List>[];

    void addPath(Uint8List bytes) {
      if (bytes.isEmpty) return;
      for (final existing in merged) {
        if (_pathsEqual(existing, bytes)) return;
      }
      merged.add(bytes);
    }

    if (pathVariants != null) {
      for (final variant in pathVariants) {
        addPath(variant);
      }
    }
    addPath(pathBytes);
    return merged;
  }

  static bool _pathsEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static ReplyInfo? parseReplyMention(String text) {
    final regex = RegExp(r'^@\[([^\]]+)\]\s+(.+)$', dotAll: true);
    final match = regex.firstMatch(text);
    if (match == null) return null;
    return ReplyInfo(
      mentionedNode: match.group(1)!,
      actualMessage: match.group(2)!,
    );
  }

  static ReactionInfo? parseReaction(String text) {
    return ReactionHelper.parseReaction(text);
  }
}

class ReplyInfo {
  final String mentionedNode;
  final String actualMessage;

  ReplyInfo({required this.mentionedNode, required this.actualMessage});
}
