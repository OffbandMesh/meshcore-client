import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../models/translation_support.dart';
import '../helpers/reaction_helper.dart';
import '../helpers/smaz.dart';
import '../utils/app_logger.dart';
import 'drift/blob_store.dart';
import 'prefs_manager.dart';

/// Merges a DM history blob with an incoming batch, entirely in JSON.
///
/// Top-level and free of any instance state so `compute` can send it to
/// another isolate (#919). Both arguments and the result are JSON strings, so
/// only two strings cross the isolate boundary rather than the object graph.
///
/// Throws if [stored] is not decodable. That is deliberate: `mergeOffThread`
/// turns the throw into a refused write, which keeps an unreadable blob intact
/// instead of replacing a whole history with just the incoming batch.
String mergeDmHistoryJson((String?, String) input) {
  final (stored, incomingJson) = input;
  final byKey = <String, Message>{};

  if (stored != null && stored.isNotEmpty) {
    for (final e in jsonDecode(stored) as List<dynamic>) {
      final m = MessageStore._messageFromJson(e as Map<String, dynamic>);
      byKey[MessageStore._mergeKey(m)] = m;
    }
  }

  for (final e in jsonDecode(incomingJson) as List<dynamic>) {
    final m = MessageStore._messageFromJson(e as Map<String, dynamic>);
    byKey[MessageStore._mergeKey(m)] = m;
  }

  final merged = byKey.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return jsonEncode(merged.map(MessageStore._messageToJson).toList());
}

/// Drops the record whose merge key is `target` from a DM history blob.
///
/// `input` is `(storedJson, targetMergeKey)`. Returns null, so nothing is
/// written, when there is no history or the target is not in it. Throws on
/// undecodable stored JSON, which `mergeOffThread` turns into a refused write.
String? dropFromDmHistoryJson((String?, String) input) {
  final (stored, target) = input;
  if (stored == null || stored.isEmpty) return null;

  final kept = <Message>[];
  var removed = false;
  for (final e in jsonDecode(stored) as List<dynamic>) {
    final m = MessageStore._messageFromJson(e as Map<String, dynamic>);
    if (MessageStore._mergeKey(m) == target) {
      removed = true;
    } else {
      kept.add(m);
    }
  }
  if (!removed) return null;

  return jsonEncode(kept.map(MessageStore._messageToJson).toList());
}

/// Converts a whole DM-history blob into one row per message (#920).
///
/// Top-level so `compute` can send it. One row per source element, with no
/// dedupe and no sorting: the migration counts the blob independently and does
/// its own deduping, so doing either here would defeat its gate.
List<MessageRowInput> dmHistoryToRows(String blobJson) {
  return (jsonDecode(blobJson) as List<dynamic>).map((e) {
    final map = e as Map<String, dynamic>;
    final m = MessageStore._messageFromJson(map);
    return MessageRowInput(
      mergeKey: MessageStore._mergeKey(m),
      timestampMs: m.timestamp.millisecondsSinceEpoch,
      // The source map re-encoded, not a re-serialisation of the decoded
      // object: a round trip through the model would rewrite any field the
      // model defaults, and this is a move, not a rewrite.
      payload: jsonEncode(map),
    );
  }).toList();
}

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
    final blobs = BlobStore.instance;

    // Rows (#920): one upsert per message being saved, costing the same at
    // 50,000 messages of history as at 50.
    if (await blobs.ensureMessageRowsMigrated(key, dmHistoryToRows)) {
      await blobs.upsertMessageRows(key, messages.map(_toRow));
      return;
    }

    // Blob fallback for a key whose migration was refused. Off the UI isolate
    // (#919): only the INCOMING messages are encoded here, and `mergeOffThread`
    // keeps the per-key serialisation and fails closed, so an undecodable blob
    // is logged and left alone rather than overwritten by a truncated one.
    final incoming = jsonEncode(messages.map(_messageToJson).toList());
    await blobs.mergeOffThread(key, incoming, mergeDmHistoryJson);
  }

  static MessageRowInput _toRow(Message m) => MessageRowInput(
    mergeKey: _mergeKey(m),
    timestampMs: m.timestamp.millisecondsSinceEpoch,
    payload: jsonEncode(_messageToJson(m)),
  );

  /// The store's own history encoding, for tests that need a blob fixture.
  /// Saves write rows now, so a test can no longer get one by saving.
  @visibleForTesting
  static String encodeHistoryForTest(List<Message> messages) =>
      jsonEncode(messages.map(_messageToJson).toList());

  static String _mergeKey(Message m) {
    if (m.messageId.isNotEmpty) return 'id:${m.messageId}';
    return 'x:${m.senderKeyHex}:${m.timestamp.millisecondsSinceEpoch}:${m.text}';
  }

  /// Explicit delete path (#343): save merges and never removes.
  ///
  /// On rows this is a single-row DELETE (#920). On the blob fallback the
  /// decode and re-encode run off the UI isolate (#919), with the per-key
  /// serialisation this path did not have before: it was a read-modify-write
  /// outside [BlobStore.synchronized], so a save landing after a delete could
  /// resurrect the deleted message.
  Future<void> removeMessage(String contactKeyHex, Message message) async {
    if (publicKeyHex.isEmpty) return;
    final key = '$keyFor$contactKeyHex';
    final blobs = BlobStore.instance;
    if (await blobs.ensureMessageRowsMigrated(key, dmHistoryToRows)) {
      await blobs.deleteMessageRow(key, _mergeKey(message));
      return;
    }
    await blobs.mergeOffThread(key, _mergeKey(message), dropFromDmHistoryJson);
  }

  Future<List<Message>> loadMessages(String contactKeyHex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn('Public key hex is not set. Cannot load messages.');
      return [];
    }
    final key = '$keyFor$contactKeyHex';
    final oldKey = '$_keyPrefix$contactKeyHex';
    final blobs = BlobStore.instance;

    // Rows (#920). Only short-circuits when rows actually exist: a key marked
    // migrated with no rows must still fall through to the legacy-key adoption
    // below, or history stored under an older key would never be picked up.
    if (await blobs.isOnMessageRows(key)) {
      final payloads = await blobs.messagePayloads(key);
      if (payloads.isNotEmpty) return _decodePayloads(payloads, key);
    }

    // Bulk data lives in drift (#335); fallback covers an unmigrated key and
    // logs loudly if it fires.
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

    // Blob history that is not in rows yet, either never migrated or just
    // adopted from a legacy key. Move it so the next load and every save runs
    // on rows.
    await blobs.ensureMessageRowsMigrated(key, dmHistoryToRows);

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList.map((json) => _messageFromJson(json)).toList();
    } catch (e) {
      return [];
    }
  }

  List<Message> _decodePayloads(List<String> payloads, String key) {
    final out = <Message>[];
    for (final p in payloads) {
      try {
        out.add(_messageFromJson(jsonDecode(p) as Map<String, dynamic>));
      } catch (e) {
        // One bad row costs one message. On the blob, one bad byte cost the
        // whole conversation.
        appLogger.error(
          'Skipping an undecodable message row in $key: $e',
          tag: 'Storage',
        );
      }
    }
    return out;
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
    // Rows too, or a cleared conversation stays readable (#920).
    await BlobStore.instance.deleteMessageRows(key);
  }

  static Map<String, dynamic> _messageToJson(Message msg) {
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
      'reactionSenders': msg.reactionSenders,
      'reactionStatuses': msg.reactionStatuses.map(
        (key, value) => MapEntry(key, value.index),
      ),
      'fourByteRoomContactKey': base64Encode(msg.fourByteRoomContactKey),
      'rxTime': msg.rxTime?.millisecondsSinceEpoch,
      'snr': msg.snr,
      'rssi': msg.rssi,
      'isFloodRoute': msg.isFloodRoute,
    };
  }

  static Message _messageFromJson(Map<String, dynamic> json) {
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
      reactionSenders: ReactionHelper.reactionSendersFromJson(
        json['reactionSenders'],
      ),
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
      snr: (json['snr'] as num?)?.toDouble(),
      rssi: json['rssi'] as int?,
      isFloodRoute: json['isFloodRoute'] as bool?,
    );
  }
}
