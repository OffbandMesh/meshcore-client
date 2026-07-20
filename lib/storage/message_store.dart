import 'dart:convert';
import 'dart:typed_data';
import '../models/message.dart';
import '../models/translation_support.dart';
import '../helpers/smaz.dart';
import '../utils/app_logger.dart';
import 'drift/blob_store.dart';
import 'prefs_manager.dart';

class MessageStore {
  static const String _keyPrefix = 'messages_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length > 10 ? value.substring(0, 10) : '';

  String get keyFor => '$_keyPrefix$publicKeyHex';

  Future<void> saveMessages(
    String contactKeyHex,
    List<Message> messages,
  ) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot save messages.');
      return;
    }
    // Merge into the persisted full history rather than overwriting it (#343).
    // The in-memory list is windowed for memory, so a plain overwrite would
    // truncate the store. Upsert by identity; deletion is explicit
    // (removeMessage).
    final key = '$keyFor$contactKeyHex';
    final byKey = <String, Message>{};

    final existing = await BlobStore.instance.readWithPrefsFallback(key);
    if (existing != null && existing.isNotEmpty) {
      try {
        for (final e in jsonDecode(existing) as List<dynamic>) {
          final m = _messageFromJson(e as Map<String, dynamic>);
          byKey[_mergeKey(m)] = m;
        }
      } catch (e) {
        appLogger.error(
          'Failed to decode existing DM history before merge; aborting save '
          'to avoid truncation: $e',
          tag: 'Storage',
        );
        return;
      }
    }
    for (final m in messages) {
      byKey[_mergeKey(m)] = m;
    }

    final merged = byKey.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await BlobStore.instance.write(
      key,
      jsonEncode(merged.map(_messageToJson).toList()),
    );
  }

  String _mergeKey(Message m) {
    if (m.messageId.isNotEmpty) return 'id:${m.messageId}';
    return 'x:${m.senderKeyHex}:${m.timestamp.millisecondsSinceEpoch}:${m.text}';
  }

  /// Explicit delete path (#343): save merges and never removes.
  Future<void> removeMessage(String contactKeyHex, Message message) async {
    if (publicKeyHex.isEmpty) return;
    final key = '$keyFor$contactKeyHex';
    final existing = await BlobStore.instance.readWithPrefsFallback(key);
    if (existing == null || existing.isEmpty) return;
    final List<dynamic> raw;
    try {
      raw = jsonDecode(existing) as List<dynamic>;
    } catch (e) {
      appLogger.error(
        'Failed to decode DM history for delete: $e',
        tag: 'Storage',
      );
      return;
    }
    final target = _mergeKey(message);
    final kept = raw
        .map((e) => _messageFromJson(e as Map<String, dynamic>))
        .where((m) => _mergeKey(m) != target)
        .toList();
    await BlobStore.instance.write(
      key,
      jsonEncode(kept.map(_messageToJson).toList()),
    );
  }

  Future<List<Message>> loadMessages(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot load messages.');
      return [];
    }
    final key = '$keyFor$contactKeyHex';
    final oldKey = '$_keyPrefix$contactKeyHex';
    // Bulk data lives in drift (#335); fallback covers an unmigrated key and
    // logs loudly if it fires.
    final blobs = BlobStore.instance;
    String? jsonString = await blobs.readWithPrefsFallback(key);

    if (jsonString == null || jsonString.isEmpty) {
      // Only touch prefs when the legacy key actually exists. An unconditional
      // remove here ran once per contact and cost a full-file rewrite each
      // time on Windows (#306).
      final prefs = PrefsManager.instance;
      final legacy = prefs.get(oldKey);
      if (legacy is String && legacy.isNotEmpty) {
        appLogger.info(
          'Migrating messages from legacy key $oldKey to $key (drift)',
        );
        await blobs.write(key, legacy);
        await prefs.remove(oldKey);
        jsonString = legacy;
      }
    }
    if (jsonString == null || jsonString.isEmpty) {
      jsonString = await blobs.readWithPrefsFallback(keyFor);
    }
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList.map((json) => _messageFromJson(json)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> clearMessages(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot clear messages.');
      return;
    }
    final key = '$keyFor$contactKeyHex';
    // Clear both backends: drift is authoritative, but a pre-migration prefs
    // copy must not survive a clear and reappear via the read fallback.
    await BlobStore.instance.delete(key);
    await PrefsManager.instance.remove(key);
  }

  Map<String, dynamic> _messageToJson(Message msg) {
    return {
      'senderKey': base64Encode(msg.senderKey),
      'text': msg.text,
      'timestamp': msg.timestamp.millisecondsSinceEpoch,
      'isOutgoing': msg.isOutgoing,
      'isCli': msg.isCli,
      'status': msg.status.index,
      'messageId': msg.messageId,
      'originalText': msg.originalText,
      'translatedText': msg.translatedText,
      'translatedLanguageCode': msg.translatedLanguageCode,
      'translationStatus': msg.translationStatus.value,
      'translationModelId': msg.translationModelId,
      'retryCount': msg.retryCount,
      'estimatedTimeoutMs': msg.estimatedTimeoutMs,
      'expectedAckHash': msg.expectedAckHash,
      'sentAt': msg.sentAt?.millisecondsSinceEpoch,
      'deliveredAt': msg.deliveredAt?.millisecondsSinceEpoch,
      'tripTimeMs': msg.tripTimeMs,
      'pathLength': msg.pathLength,
      'pathBytes': msg.pathBytes.isNotEmpty
          ? base64Encode(msg.pathBytes)
          : null,
      'reactions': msg.reactions,
      'reactionStatuses': msg.reactionStatuses.map(
        (key, value) => MapEntry(key, value.index),
      ),
      'fourByteRoomContactKey': base64Encode(msg.fourByteRoomContactKey),
      'rxTime': msg.rxTime?.millisecondsSinceEpoch,
    };
  }

  Message _messageFromJson(Map<String, dynamic> json) {
    final rawText = json['text'] as String;
    final isCli = json['isCli'] as bool? ?? false;
    final decodedText = isCli
        ? rawText
        : (Smaz.tryDecodePrefixed(rawText) ?? rawText);
    return Message(
      senderKey: Uint8List.fromList(base64Decode(json['senderKey'] as String)),
      text: decodedText,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      isOutgoing: json['isOutgoing'] as bool,
      isCli: isCli,
      status: MessageStatus.values[json['status'] as int],
      messageId: json['messageId'] as String?,
      originalText: json['originalText'] as String?,
      translatedText: json['translatedText'] as String?,
      translatedLanguageCode: json['translatedLanguageCode'] as String?,
      translationStatus: parseMessageTranslationStatus(
        json['translationStatus'],
      ),
      translationModelId: json['translationModelId'] as String?,
      retryCount: json['retryCount'] as int? ?? 0,
      estimatedTimeoutMs: json['estimatedTimeoutMs'] as int?,
      expectedAckHash: json['expectedAckHash'] as int? ?? 0,
      sentAt: json['sentAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['sentAt'] as int)
          : null,
      deliveredAt: json['deliveredAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['deliveredAt'] as int)
          : null,
      tripTimeMs: json['tripTimeMs'] as int?,
      pathLength: json['pathLength'] as int?,
      pathBytes: json['pathBytes'] != null
          ? Uint8List.fromList(base64Decode(json['pathBytes'] as String))
          : Uint8List(0),
      reactions:
          (json['reactions'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, value as int),
          ) ??
          {},
      reactionStatuses:
          (json['reactionStatuses'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, MessageStatus.values[value as int]),
          ) ??
          {},
      fourByteRoomContactKey: json['fourByteRoomContactKey'] != null
          ? Uint8List.fromList(
              base64Decode(json['fourByteRoomContactKey'] as String),
            )
          : null,
      rxTime: json['rxTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['rxTime'] as int)
          : null,
    );
  }
}
