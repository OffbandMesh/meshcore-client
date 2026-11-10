import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:meshcore_open/utils/app_logger.dart';

import '../models/channel_message.dart';
import '../models/translation_support.dart';
import '../helpers/reaction_helper.dart';
import '../helpers/smaz.dart';
import 'drift/blob_store.dart';

/// Merges `incomingJson` into the stored channel history, off the UI isolate.
///
/// Top-level because `compute` sends it to another isolate; a closure capturing
/// the store would not be sendable. Visible (not `_`-private) only so the test
/// can call it directly and assert the merge semantics without an isolate.
///
/// Semantics are deliberately identical to the inline merge this replaced:
/// upsert by [ChannelMessageStore._mergeKey], the incoming copy wins so edits,
/// reactions and status updates are captured, and the result is sorted by
/// timestamp. Deletion has its own path, so this never resurrects a deleted
/// message.
///
/// **Throws** when the stored JSON will not decode, rather than merging into an
/// empty base. [BlobStore.mergeOffThread] logs and declines to write, so a
/// blob that cannot be read is never replaced by a truncated one (#334's
/// original inline behaviour, preserved).
String mergeChannelHistoryJson((String?, String) input) {
  final (stored, incomingJson) = input;
  final byKey = <String, ChannelMessage>{};

  if (stored != null && stored.isNotEmpty) {
    // No try/catch: a decode failure must propagate so the caller refuses the
    // write. Swallowing it here would silently truncate the history.
    for (final e in jsonDecode(stored) as List<dynamic>) {
      final m = ChannelMessageStore._messageFromJson(e as Map<String, dynamic>);
      byKey[ChannelMessageStore._mergeKey(m)] = m;
    }
  }

  for (final e in jsonDecode(incomingJson) as List<dynamic>) {
    final m = ChannelMessageStore._messageFromJson(e as Map<String, dynamic>);
    byKey[ChannelMessageStore._mergeKey(m)] = m;
  }

  final merged = byKey.values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return jsonEncode(merged.map(ChannelMessageStore._messageToJson).toList());
}

/// Drops the record whose merge key is `target` from a channel history blob.
///
/// `input` is `(storedJson, targetMergeKey)`. Top-level and static-only so
/// `compute` can send it (#919). Returns null, so nothing is written, when
/// there is no history or the target is not in it: re-encoding 5 MB to change
/// nothing is exactly the cost this Epic exists to stop paying.
///
/// Throws on undecodable stored JSON, which `mergeOffThread` turns into a
/// refused write. That matches the inline code it replaces, which logged and
/// left the blob alone.
String? dropFromChannelHistoryJson((String?, String) input) {
  final (stored, target) = input;
  if (stored == null || stored.isEmpty) return null;

  final kept = <ChannelMessage>[];
  var removed = false;
  for (final e in jsonDecode(stored) as List<dynamic>) {
    final m = ChannelMessageStore._messageFromJson(e as Map<String, dynamic>);
    if (ChannelMessageStore._mergeKey(m) == target) {
      removed = true;
    } else {
      kept.add(m);
    }
  }
  if (!removed) return null;

  return jsonEncode(kept.map(ChannelMessageStore._messageToJson).toList());
}

/// Converts a whole channel-history blob into one row per message (#920).
///
/// Top-level so `compute` can send it. Returns exactly one row per element of
/// the source array, with no dedupe and no sorting: the migration's gate
/// compares this count against an independent count of the blob, and does its
/// own deduping, so doing either here would defeat the check.
///
/// Throws on undecodable JSON, which the migration turns into a refusal that
/// leaves the blob as the source of truth.
List<MessageRowInput> channelHistoryToRows(String blobJson) {
  return (jsonDecode(blobJson) as List<dynamic>).map((e) {
    final map = e as Map<String, dynamic>;
    final m = ChannelMessageStore._messageFromJson(map);
    return MessageRowInput(
      mergeKey: ChannelMessageStore._mergeKey(m),
      timestampMs: m.timestamp.millisecondsSinceEpoch,
      // The source map, re-encoded, NOT a re-serialisation of the decoded
      // object. A round trip through the model would quietly rewrite any field
      // the model defaults, and this is a move, not a rewrite.
      payload: jsonEncode(map),
    );
  }).toList();
}

class ChannelMessageStore {
  static const String _keyPrefix = 'channel_messages_';

  /// Marks a PSK-identity key so it can never collide with a legacy slot-index
  /// key (a PSK is 32 hex chars; an index is a small integer). (#194)
  static const String _pskMarker = 'psk_';

  String publicKeyHex = '';
  set setPublicKeyHex(String value) =>
      publicKeyHex = value.length >= 10 ? value.substring(0, 10) : '';

  /// Resolves a channel slot index to its channel's PSK hex, a stable identity
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
  /// The index fallback is legitimate on a READ before a channel list has
  /// loaded, but it reads a DIFFERENT key: if history was already migrated to
  /// the PSK key, the caller gets an empty list that is indistinguishable from
  /// data loss. SAFELANE 6 - this must never be silent. Falling back where a
  /// resolver exists means the channel list was not ready, which is the #333
  /// race.
  ///
  /// A WRITE must never land on the index fallback: the one-time adoption in
  /// [loadChannelMessages] only runs while the PSK key is EMPTY, so a message
  /// written to the index key of a channel that already has PSK-keyed history
  /// is orphaned - stored, never read again. Since #1062 the connector files
  /// live traffic only after the channel list is confirmed (ingress barrier +
  /// fail-closed slot lookup), so a write-side fallback is a defect; it is
  /// logged as an error and [forWrite] marks the call sites that save, remove
  /// or clear. (#1063)
  String _storageKey(int channelIndex, {bool forWrite = false}) {
    final pskHex = channelPskResolver?.call(channelIndex);
    if (pskHex != null && pskHex.isNotEmpty) {
      return '$keyFor$_pskMarker$pskHex';
    }
    if (channelPskResolver != null) {
      if (forWrite) {
        appLogger.error(
          'WRITE for channel $channelIndex fell back to the slot-index key: '
          'the slot did not resolve to a PSK. If this channel already has '
          'PSK-keyed history, this write is orphaned (adoption only runs on '
          'an empty PSK key). Post-#1062 ingress cannot reach this; a user '
          'action on an unconfirmed slot can. (#1063)',
          tag: 'Storage',
        );
      } else {
        appLogger.warn(
          'Channel $channelIndex has no PSK yet; falling back to the '
          'slot-index key. Any history already migrated to the PSK key will '
          'read as EMPTY. This means the channel list was not loaded first '
          '(#333).',
          tag: 'Storage',
        );
      }
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
    // Merge into the persisted full history rather than overwriting it. The
    // in-memory list is windowed to the most recent N for memory, so a plain
    // overwrite would truncate the store to N and erode old history (#343).
    // Upsert by identity: keep older persisted messages, add new ones, and let
    // the in-memory copy win so edits/reactions/status updates are captured.
    // Deletion has its own path (removeChannelMessage) so this never
    // resurrects a message the user deleted.
    final key = _storageKey(channelIndex, forWrite: true);
    final blobs = BlobStore.instance;

    // Rows (#920): one upsert per message in the list, which costs the same
    // whether 50 or 50,000 messages are already stored. #919 moved the
    // whole-history re-encode to another isolate; this removes it. The cost is
    // proportional to the in-memory window being saved, never to the history.
    if (await blobs.ensureMessageRowsMigrated(key, channelHistoryToRows)) {
      await blobs.upsertMessageRows(key, messages.map(_toRow));
      return;
    }

    // Blob fallback, for a key whose migration was refused. Still correct,
    // still off the UI isolate (#919): only the INCOMING messages are encoded
    // here, and decoding the stored history, merging and re-encoding it runs on
    // another isolate. `mergeOffThread` keeps the per-key serialisation that
    // stops two saves clobbering each other, and fails closed: if the stored
    // JSON will not decode, the key is not written.
    final incoming = jsonEncode(messages.map(_messageToJson).toList());
    await blobs.mergeOffThread(key, incoming, mergeChannelHistoryJson);
  }

  static MessageRowInput _toRow(ChannelMessage m) => MessageRowInput(
    mergeKey: _mergeKey(m),
    timestampMs: m.timestamp.millisecondsSinceEpoch,
    payload: jsonEncode(_messageToJson(m)),
  );

  /// The store's own history encoding, for tests that need a blob fixture.
  ///
  /// Exists so a test never hand-writes one: a hand-rolled fixture rots the
  /// moment a non-null field joins the schema, which is exactly how the #919
  /// tests first failed. Saving through [saveChannelMessages] cannot serve that
  /// purpose any more, because saves write rows now.
  @visibleForTesting
  static String encodeHistoryForTest(List<ChannelMessage> messages) =>
      jsonEncode(messages.map(_messageToJson).toList());

  /// Stable identity for merge/dedupe. messageId when present, else a composite
  /// that distinguishes distinct messages that share no id.
  static String _mergeKey(ChannelMessage m) {
    if (m.messageId.isNotEmpty) return 'id:${m.messageId}';
    // Include the sender: two different senders can post identical text at the
    // same timestamp without a messageId, and would otherwise collide and lose
    // one (Gemini review, 2026-07-20).
    final sender = m.senderKey == null
        ? ''
        : m.senderKey!.map((b) => b.toRadixString(16)).join();
    return 'x:$sender:${m.packetHash ?? ''}:'
        '${m.timestamp.millisecondsSinceEpoch}:${m.text}';
  }

  /// Removes a single message from the persisted history. The explicit delete
  /// path (#343): save merges and never removes, so deletion cannot go through
  /// save.
  ///
  /// On rows this is a single-row DELETE (#920). On the blob fallback the
  /// decode and re-encode run off the UI isolate (#919), because a delete
  /// rewrites the whole blob and so blocked the UI for as long as a save did,
  /// right when the user had just tapped something.
  Future<void> removeChannelMessage(
    int channelIndex,
    ChannelMessage message,
  ) async {
    if (publicKeyHex.isEmpty) return;
    final key = _storageKey(channelIndex, forWrite: true);
    final blobs = BlobStore.instance;
    if (await blobs.ensureMessageRowsMigrated(key, channelHistoryToRows)) {
      await blobs.deleteMessageRow(key, _mergeKey(message));
      return;
    }
    await blobs.mergeOffThread(
      key,
      _mergeKey(message),
      dropFromChannelHistoryJson,
    );
  }

  /// Load messages for a specific channel
  Future<List<ChannelMessage>> loadChannelMessages(int channelIndex) async {
    if (publicKeyHex.isEmpty) {
      appLogger.warn(
        'Public key hex is not set. Cannot load channel messages.',
      );
      return [];
    }
    final blobs = BlobStore.instance;
    final key = _storageKey(channelIndex);

    // Rows (#920). The legacy-key adoption below works on blobs, so it has to
    // run before this key can be considered settled: a key with no blob and no
    // rows is migrated as "empty" and would then never adopt its slot-index
    // history. So rows are only authoritative once they exist OR the blob is
    // genuinely empty after adoption had its chance.
    if (await blobs.isOnMessageRows(key)) {
      final payloads = await blobs.messagePayloads(key);
      if (payloads.isNotEmpty) {
        return _decodePayloads(payloads, key);
      }
    }

    // Bulk data lives in drift (#335); the fallback covers an unmigrated key
    // and logs loudly if it fires.
    String? jsonString = await blobs.readWithPrefsFallback(key);

    // One-time migration into the PSK-identity key. Only runs when the PSK is
    // known (key != index key). Adopts pre-#194 history keyed by slot index,
    // device-scoped first, then the oldest unscoped key, and drops the source.
    // Build-B (#193) clears a slot's index history on mismatched reuse, so a
    // live slot's index data is the channel's own by the time we read here.
    if ((jsonString == null || jsonString.isEmpty) &&
        key != _indexKey(channelIndex)) {
      for (final legacyKey in [
        _indexKey(channelIndex),
        '$_keyPrefix$channelIndex', // pre-device-scoping, unscoped index key
      ]) {
        // Legacy keys may sit in either backend depending on when this
        // install last ran, so check both.
        final legacy = await blobs.readWithPrefsFallback(legacyKey);
        if (legacy != null && legacy.isNotEmpty) {
          appLogger.info(
            'Migrating channel messages $legacyKey -> $key (PSK-keyed, #194)',
          );
          // Under the key lock, and MERGE rather than overwrite: a save may
          // have landed on the PSK key between the read above and here, and a
          // blind write would clobber it (Gemini review). Union keeps both the
          // adopted legacy history and any freshly-saved message.
          jsonString = await blobs.synchronized(key, () async {
            final byKey = <String, ChannelMessage>{};
            for (final srcJson in [await blobs.read(key), legacy]) {
              if (srcJson == null || srcJson.isEmpty) continue;
              try {
                for (final e in jsonDecode(srcJson) as List<dynamic>) {
                  final m = _messageFromJson(e as Map<String, dynamic>);
                  byKey[_mergeKey(m)] = m;
                }
              } catch (_) {
                // Skip an undecodable source rather than aborting the adoption.
              }
            }
            final merged = byKey.values.toList()
              ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
            final encoded = jsonEncode(merged.map(_messageToJson).toList());
            await blobs.write(key, encoded);
            return encoded;
          });
          await blobs.deleteEverywhere(legacyKey);
          break;
        }
      }
    }
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    // The blob holds history that is not in rows yet, either because this key
    // has never been migrated or because adoption above just brought legacy
    // history in. Move it now so the next load and every save is on rows.
    await blobs.ensureMessageRowsMigrated(key, channelHistoryToRows);

    try {
      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      return jsonList.map((json) => _messageFromJson(json)).toList();
    } catch (e) {
      appLogger.error('Failed to parse channel messages for $key: $e');
      return [];
    }
  }

  List<ChannelMessage> _decodePayloads(List<String> payloads, String key) {
    final out = <ChannelMessage>[];
    for (final p in payloads) {
      try {
        out.add(_messageFromJson(jsonDecode(p) as Map<String, dynamic>));
      } catch (e) {
        // One unreadable row must not cost the whole channel. Unlike the blob,
        // where a bad byte took every message with it, rows fail one at a time.
        appLogger.error(
          'Skipping an undecodable message row in $key: $e',
          tag: 'Storage',
        );
      }
    }
    return out;
  }

  /// Clear a channel's history outright: BOTH the PSK-identity key and the
  /// raw slot-index key. This is the true-delete path (deleteChannel, the
  /// user's explicit clear) - the channel's own history must be gone.
  /// Slot reassignment uses [clearLegacySlotHistory] instead, which keeps the
  /// outgoing occupant's PSK-keyed history. (#1063)
  Future<void> clearChannelMessages(int channelIndex) async {
    final blobs = BlobStore.instance;
    for (final key in {
      _storageKey(channelIndex, forWrite: true),
      _indexKey(channelIndex),
    }) {
      await blobs.deleteEverywhere(key);
      // Rows as well, or a clear would leave the history readable (#920).
      await blobs.deleteMessageRows(key);
    }
  }

  /// Purges only the LEGACY slot-keyed history for [channelIndex]: the
  /// device-scoped index key and the pre-device-scoping unscoped key. Used
  /// when a slot is reassigned to a different channel (#193): without this,
  /// [loadChannelMessages]' one-time adoption would migrate the previous
  /// occupant's pre-#194 history onto the new occupant. The previous
  /// occupant's PSK-keyed history is NOT touched, so re-adding that channel
  /// later restores its messages. (#1063)
  Future<void> clearLegacySlotHistory(int channelIndex) async {
    final blobs = BlobStore.instance;
    for (final key in {_indexKey(channelIndex), '$_keyPrefix$channelIndex'}) {
      await blobs.deleteEverywhere(key);
      await blobs.deleteMessageRows(key);
    }
  }

  String _pskKey(String pskHex) => '$keyFor$_pskMarker$pskHex';

  /// Moves every message stored under [fromPskHex] to [toPskHex], for a key
  /// change the user chose to keep history across (#1128).
  ///
  /// Copy, verify, then delete: an interruption leaves the history under both
  /// keys, never under neither. A message already under the new key keeps
  /// that copy. Only the copied rows are deleted, and the pass repeats, so a
  /// message saved to the old key mid-move is moved too rather than lost.
  /// Returns how many messages the new key gained, or null when the move
  /// could not be done safely, in which case whatever was not yet moved is
  /// left under the old key and the reason is logged as an error.
  Future<int?> moveChannelHistory(String fromPskHex, String toPskHex) async {
    final what =
        'channel history psk ${_fingerprint(fromPskHex)} -> '
        '${_fingerprint(toPskHex)}';
    if (publicKeyHex.isEmpty || fromPskHex.isEmpty || toPskHex.isEmpty) {
      appLogger.error(
        'NOT moving $what: no radio key or no channel key',
        tag: 'Storage',
      );
      return null;
    }
    if (fromPskHex == toPskHex) return 0;
    final from = _pskKey(fromPskHex);
    final to = _pskKey(toPskHex);
    final blobs = BlobStore.instance;

    for (final key in [from, to]) {
      if (!await blobs.ensureMessageRowsMigrated(key, channelHistoryToRows)) {
        appLogger.error(
          'NOT moving $what: $key could not be moved onto rows. Both keys '
          'are unchanged.',
          tag: 'Storage',
        );
        return null;
      }
    }

    var moved = 0;
    var gained = 0;
    for (var pass = 0; pass < 3; pass++) {
      final payloads = await blobs.messagePayloads(from);
      if (payloads.isEmpty) break;
      final already = await blobs.messageMergeKeys(to);
      final sourceKeys = <String>{};
      final rows = <MessageRowInput>[];
      for (final payload in payloads) {
        final ChannelMessage m;
        try {
          m = _messageFromJson(jsonDecode(payload) as Map<String, dynamic>);
        } catch (e) {
          appLogger.error(
            'NOT moving $what: a stored message will not decode ($e). '
            '$moved message(s) were moved before this; the rest stay under '
            'the old key.',
            tag: 'Storage',
          );
          return null;
        }
        final mergeKey = _mergeKey(m);
        sourceKeys.add(mergeKey);
        if (already.contains(mergeKey)) continue;
        rows.add(
          MessageRowInput(
            mergeKey: mergeKey,
            timestampMs: m.timestamp.millisecondsSinceEpoch,
            payload: payload,
          ),
        );
      }

      await blobs.upsertMessageRows(to, rows);
      final missing = sourceKeys.difference(await blobs.messageMergeKeys(to));
      if (missing.isNotEmpty) {
        appLogger.error(
          'NOT finishing $what: ${missing.length} of ${sourceKeys.length} '
          'messages did not read back under the new key. They stay under the '
          'old key.',
          tag: 'Storage',
        );
        return null;
      }
      await blobs.deleteMessageRowsIn(from, sourceKeys);
      moved += sourceKeys.length;
      gained += rows.length;
    }

    final left = await blobs.messageRowCount(from);
    if (left > 0) {
      appLogger.error(
        'NOT finishing $what: $left message(s) kept arriving under the old '
        'key; they stay there.',
        tag: 'Storage',
      );
      return null;
    }
    await blobs.deleteEverywhere(from);
    appLogger.info(
      'Moved $what: $moved message(s), $gained new to the new key (#1128)',
      tag: 'Storage',
    );
    return gained;
  }

  /// Deletes everything stored under [pskHex] for this radio, the history
  /// half of Delete Channel, addressed by key rather than slot (#1128).
  Future<void> deleteChannelHistory(String pskHex) async {
    if (publicKeyHex.isEmpty || pskHex.isEmpty) {
      appLogger.error(
        'NOT deleting channel history psk ${_fingerprint(pskHex)}: no radio '
        'key or no channel key',
        tag: 'Storage',
      );
      return;
    }
    final key = _pskKey(pskHex);
    final blobs = BlobStore.instance;
    final count = await blobs.messageRowCount(key);
    await blobs.deleteEverywhere(key);
    await blobs.deleteMessageRows(key);
    appLogger.info(
      'Deleted channel history psk ${_fingerprint(pskHex)}: $count message '
      'row(s) (#1128)',
      tag: 'Storage',
    );
  }

  /// Deletes this radio's channel history that no channel on it can show:
  /// history under a key the radio does not hold, and pre-#194 slot history
  /// for a slot that holds nothing. History is never kept hidden (#1128).
  ///
  /// The caller passes the radio's fully confirmed channel list, with no
  /// erased slots. Restore (#1117) only has work when slots are erased, so
  /// its channels' history is never what this sees.
  ///
  /// Returns the deleted keys, each logged with its row count.
  Future<List<String>> purgeHistoryNotOnRadio({
    required Set<String> radioPskHex,
    required Set<int> occupiedSlots,
  }) async {
    if (publicKeyHex.isEmpty) return const [];
    if (radioPskHex.isEmpty) {
      appLogger.warn(
        'Radio $publicKeyHex reports no channels at all; not deleting any '
        'channel history on that (#1128)',
        tag: 'Storage',
      );
      return const [];
    }
    final blobs = BlobStore.instance;
    final pskPrefix = '$keyFor$_pskMarker';
    final slotKey = RegExp('^${RegExp.escape(keyFor)}(\\d+)\$');
    final candidates = {
      ...await blobs.keysWithPrefix(keyFor),
      ...(await blobs.messageStoreKeys()).where((k) => k.startsWith(keyFor)),
    };

    final deleted = <String>[];
    for (final key in candidates.toList()..sort()) {
      final String label;
      if (key.startsWith(pskPrefix)) {
        final pskHex = key.substring(pskPrefix.length);
        if (radioPskHex.contains(pskHex)) continue;
        label = 'psk ${_fingerprint(pskHex)}';
      } else {
        final slot = slotKey.firstMatch(key)?.group(1);
        if (slot == null || occupiedSlots.contains(int.parse(slot))) continue;
        label = 'empty slot $slot (pre-#194)';
      }
      final count = await blobs.messageRowCount(key);
      await blobs.deleteEverywhere(key);
      await blobs.deleteMessageRows(key);
      deleted.add(key);
      appLogger.info(
        'Deleted hidden channel history of radio $publicKeyHex, $label: '
        '$count message row(s), no channel on the radio shows it (#1128)',
        tag: 'Storage',
      );
    }
    appLogger.info(
      'Hidden channel history check for radio $publicKeyHex: '
      '${candidates.length} stored key(s) against ${radioPskHex.length} '
      'channel(s) on the radio, ${deleted.length} deleted (#1128)',
      tag: 'Storage',
    );
    return deleted;
  }

  static String _fingerprint(String pskHex) => pskHex.isEmpty
      ? 'none'
      : sha256.convert(utf8.encode(pskHex)).toString().substring(0, 8);

  /// Clear all channel messages
  Future<void> clearAllChannelMessages() async {
    final blobs = BlobStore.instance;
    for (final key in await blobs.keysWithPrefix(keyFor)) {
      await blobs.deleteEverywhere(key);
      await blobs.deleteMessageRows(key);
    }
    // Row-only keys have no blob left to list, so clear by row key too.
    for (final key in await blobs.messageStoreKeys()) {
      if (key.startsWith(keyFor)) await blobs.deleteMessageRows(key);
    }
  }

  /// Convert ChannelMessage to JSON map
  static Map<String, dynamic> _messageToJson(ChannelMessage msg) {
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
      'reactionSenders': msg.reactionSenders,
    };
  }

  /// Convert JSON map to ChannelMessage
  static ChannelMessage _messageFromJson(Map<String, dynamic> json) {
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
      reactionSenders: ReactionHelper.reactionSendersFromJson(
        json['reactionSenders'],
      ),
    );
  }

  static Map<String, dynamic> _repeatToJson(Repeat repeat) {
    return {
      'repeaterKey': repeat.repeaterKey != null
          ? base64Encode(repeat.repeaterKey!)
          : null,
      'repeaterName': repeat.repeaterName,
      'tripTimeMs': repeat.tripTimeMs,
      'path': repeat.path?.map((bytes) => base64Encode(bytes)).toList() ?? [],
    };
  }

  static Repeat _repeatFromJson(Map<String, dynamic> json) {
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
