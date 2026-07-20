import 'dart:convert';
import 'dart:typed_data';
import 'package:meshcore_open/utils/app_logger.dart';

import '../models/channel_message.dart';
import '../models/translation_support.dart';
import '../helpers/smaz.dart';
import 'prefs_manager.dart';

class ChannelMessageStore {
  static const String _keyPrefix = 'channel_messages_';

  /// Marks a PSK-identity key so it can never collide with a legacy slot-index
  /// key (a PSK is 32 hex chars; an index is a small integer). (#194)
  static const String _pskMarker = 'psk_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length >= 10 ? value.substring(0, 10) : '';

  /// Resolves a channel slot index to its channel's PSK hex — a stable identity
  /// that does not change when the channel moves slots. Set by the connector.
  /// When it yields a non-empty hex, history is keyed by PSK so reusing a slot
  /// can never surface a previous occupant's messages. Falls back to the slot
  /// index only while the PSK is unknown (channel not yet synced). (#194)
  String? Function(int index)? channelPskResolver;

  String get keyFor => '$_keyPrefix$publicKeyHex';

  /// Device-scoped slot-index key (the pre-#194 scheme; still used as a
  /// migration source and as the fallback when the PSK is unknown).
  String _indexKey(int channelIndex) => '$keyFor$channelIndex';

  /// Active storage key: PSK identity when known, else the slot index.
  ///
  /// The index fallback is legitimate before a channel list has loaded, but it
  /// reads a DIFFERENT key: if history was already migrated to the PSK key, the
  /// caller gets an empty list that is indistinguishable from data loss.
  /// SAFELANE 6 - this must never be silent. Falling back where a resolver
  /// exists means the channel list was not ready, which is the #333 race.
  String _storageKey(int channelIndex) {
    final pskHex = channelPskResolver?.call(channelIndex);
    if (pskHex != null && pskHex.isNotEmpty) {
      return '$keyFor$_pskMarker$pskHex';
    }
    if (channelPskResolver != null) {
      appLogger.warn(
        'Channel $channelIndex has no PSK yet; falling back to the slot-index '
        'key. Any history already migrated to the PSK key will read as EMPTY. '
        'This means the channel list was not loaded first (#333).',
        tag: 'Storage',
      );
    }
    return _indexKey(channelIndex);
  }

  /// Save messages for a specific channel
  Future<void> saveChannelMessages(
    int channelIndex,
    List<ChannelMessage> messages,
  ) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot save channel messages.',
      );
      return;
    }
    final prefs = PrefsManager.instance;
    final jsonList = messages.map((msg) => _messageToJson(msg)).toList();
    await prefs.setString(_storageKey(channelIndex), jsonEncode(jsonList));
  }

  /// Load messages for a specific channel
  Future<List<ChannelMessage>> loadChannelMessages(int channelIndex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load channel messages.',
      );
      return [];
    }
    final prefs = PrefsManager.instance;
    final key = _storageKey(channelIndex);
    String? jsonString = prefs.getString(key);

    // One-time migration into the PSK-identity key. Only runs when the PSK is
    // known (key != index key). Adopts pre-#194 history keyed by slot index —
    // device-scoped first, then the oldest unscoped key — and drops the source.
    // Build-B (#193) clears a slot's index history on mismatched reuse, so a
    // live slot's index data is the channel's own by the time we read here.
    if ((jsonString == null || jsonString.isEmpty) &&
        key != _indexKey(channelIndex)) {
      for (final legacyKey in [
        _indexKey(channelIndex),
        '$_keyPrefix$channelIndex', // pre-device-scoping, unscoped index key
      ]) {
        final legacy = prefs.getString(legacyKey);
        if (legacy != null && legacy.isNotEmpty) {
          appLogger.info(
            'Migrating channel messages $legacyKey -> $key (PSK-keyed, #194)',
          );
          await prefs.setString(key, legacy);
          await prefs.remove(legacyKey);
          jsonString = legacy;
          break;
        }
      }
    }
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }
    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList.map((json) => _messageFromJson(json)).toList();
    } catch (e) {
      appLogger.error('Failed to parse channel messages for $key: $e');
      return [];
    }
  }

  /// Clear messages for a specific channel slot. Removes BOTH the PSK-identity
  /// key and the raw slot-index key: deleteChannel needs the channel's own
  /// history gone, and setChannel's reuse-clear (#193) needs any stale
  /// slot-index history gone so it can't be migrated onto the new occupant.
  Future<void> clearChannelMessages(int channelIndex) async {
    final prefs = PrefsManager.instance;
    await prefs.remove(_storageKey(channelIndex));
    await prefs.remove(_indexKey(channelIndex));
  }

  /// Clear all channel messages
  Future<void> clearAllChannelMessages() async {
    final prefs = PrefsManager.instance;
    final keys = prefs.getKeys().where((k) => k.startsWith(keyFor)).toList();
    for (var key in keys) {
      await prefs.remove(key);
    }
  }

  /// Convert ChannelMessage to JSON map
  Map<String, dynamic> _messageToJson(ChannelMessage msg) {
    return {
      'senderKey': msg.senderKey != null ? base64Encode(msg.senderKey!) : null,
      'senderName': msg.senderName,
      'text': msg.text,
      'originalText': msg.originalText,
      'translatedText': msg.translatedText,
      'translatedLanguageCode': msg.translatedLanguageCode,
      'translationStatus': msg.translationStatus.value,
      'translationModelId': msg.translationModelId,
      'timestamp': msg.timestamp.millisecondsSinceEpoch,
      'isOutgoing': msg.isOutgoing,
      'status': msg.status.index,
      'rxTime': msg.rxTime?.millisecondsSinceEpoch,
      'channelIndex': msg.channelIndex,
      'repeatCount': msg.repeatCount,
      'pathLength': msg.pathLength,
      'pathBytes': base64Encode(msg.pathBytes),
      'pathVariants': msg.pathVariants.map(base64Encode).toList(),
      'repeats': msg.repeats.map(_repeatToJson).toList(),
      'messageId': msg.messageId,
      'packetHash': msg.packetHash,
      'replyToMessageId': msg.replyToMessageId,
      'replyToSenderName': msg.replyToSenderName,
      'replyToText': msg.replyToText,
      'reactions': msg.reactions,
    };
  }

  /// Convert JSON map to ChannelMessage
  ChannelMessage _messageFromJson(Map<String, dynamic> json) {
    final rawText = json['text'] as String;
    final decodedText = Smaz.tryDecodePrefixed(rawText) ?? rawText;
    return ChannelMessage(
      senderKey: json['senderKey'] != null
          ? Uint8List.fromList(base64Decode(json['senderKey']))
          : null,
      senderName: json['senderName'] as String,
      text: decodedText,
      originalText: json['originalText'] as String?,
      translatedText: json['translatedText'] as String?,
      translatedLanguageCode: json['translatedLanguageCode'] as String?,
      translationStatus: parseMessageTranslationStatus(
        json['translationStatus'],
      ),
      translationModelId: json['translationModelId'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      isOutgoing: json['isOutgoing'] as bool,
      status: ChannelMessageStatus.values[json['status'] as int],
      rxTime: json['rxTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['rxTime'] as int)
          : null,
      repeatCount: (json['repeatCount'] as int?) ?? 0,
      pathLength: json['pathLength'] as int?,
      pathBytes: json['pathBytes'] != null
          ? Uint8List.fromList(base64Decode(json['pathBytes'] as String))
          : Uint8List(0),
      pathVariants: (json['pathVariants'] as List<dynamic>?)
          ?.map((entry) => Uint8List.fromList(base64Decode(entry as String)))
          .toList(),
      repeats:
          (json['repeats'] as List<dynamic>?)
              ?.map((entry) => _repeatFromJson(entry as Map<String, dynamic>))
              .toList() ??
          const [],
      channelIndex: json['channelIndex'] as int?,
      messageId: json['messageId'] as String?,
      packetHash: json['packetHash'] as String?,
      replyToMessageId: json['replyToMessageId'] as String?,
      replyToSenderName: json['replyToSenderName'] as String?,
      replyToText: json['replyToText'] as String?,
      reactions:
          (json['reactions'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, value as int),
          ) ??
          {},
    );
  }

  Map<String, dynamic> _repeatToJson(Repeat repeat) {
    return {
      'repeaterKey': repeat.repeaterKey != null
          ? base64Encode(repeat.repeaterKey!)
          : null,
      'repeaterName': repeat.repeaterName,
      'tripTimeMs': repeat.tripTimeMs,
      'path': repeat.path?.map((bytes) => base64Encode(bytes)).toList() ?? [],
    };
  }

  Repeat _repeatFromJson(Map<String, dynamic> json) {
    return Repeat(
      repeaterKey: json['repeaterKey'] != null
          ? Uint8List.fromList(base64Decode(json['repeaterKey']))
          : null,
      repeaterName: json['repeaterName'] as String? ?? 'Unknown',
      tripTimeMs: json['tripTimeMs'] as int? ?? 0,
      path: (json['path'] as List<dynamic>?)
          ?.map((entry) => Uint8List.fromList(base64Decode(entry as String)))
          .toList(),
    );
  }
}
