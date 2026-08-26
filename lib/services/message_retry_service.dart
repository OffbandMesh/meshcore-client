import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../models/path_selection.dart';
import 'app_settings_service.dart';
import 'app_debug_log_service.dart';

class _AckHistoryEntry {
  final String messageId;
  final List<int> ackHashes;
  final DateTime timestamp;

  _AckHistoryEntry({
    required this.messageId,
    required this.ackHashes,
    required this.timestamp,
  });
}

/// (messageId, timestamp, attemptIndex, pathSelection), stored per ACK hash
/// for O(1) lookup.  [pathSelection] snapshots the route used for this
/// specific attempt so that a late PUSH_CODE_SEND_CONFIRMED credits the
/// correct path even when the message has since been retried on a different
/// route.
typedef AckHashMapping = ({
  String messageId,
  DateTime timestamp,
  int attemptIndex,
  PathSelection? pathSelection,
});

class RetryServiceConfig {
  final Future<void> Function(Contact, String, int, int) sendMessage;
  final void Function(String, Message) addMessage;
  final void Function(Message) updateMessage;
  final Function(Contact)? clearContactPath;
  final Function(Contact, Uint8List, int)? setContactPath;
  final int Function(int pathLength, int messageBytes, {String? contactKey})?
  calculateTimeout;
  final Uint8List? Function()? getSelfPublicKey;
  final String Function(Contact, String)? prepareContactOutboundText;
  final AppSettingsService? appSettingsService;
  final AppDebugLogService? debugLogService;
  final void Function(String, PathSelection, bool, int?)? recordPathResult;
  final void Function(String, int, int, int)? onDeliveryObserved;
  final PathSelection? Function(
    String contactKey,
    int attemptIndex,
    int maxRetries,
    List<PathSelection> recentSelections,
  )?
  selectRetryPath;

  const RetryServiceConfig({
    required this.sendMessage,
    required this.addMessage,
    required this.updateMessage,
    this.clearContactPath,
    this.setContactPath,
    this.calculateTimeout,
    this.getSelfPublicKey,
    this.prepareContactOutboundText,
    this.appSettingsService,
    this.debugLogService,
    this.recordPathResult,
    this.onDeliveryObserved,
    this.selectRetryPath,
  });
}

class MessageRetryService extends ChangeNotifier {
  static const int maxAckHistorySize = 100;
  // How long to wait for the radio's RESP_CODE_SENT before treating an
  // apparently-sent message as failed so it can't wedge the queue (#395).
  static const int _sentConfirmationTimeoutMs = 8000;
  int _maxRetries = 5;
  int get maxRetries => _maxRetries;

  final Map<String, Timer> _timeoutTimers = {};
  final Map<String, Timer> _sentConfirmationTimers = {};
  final Map<String, Message> _pendingMessages = {};
  final Map<String, Contact> _pendingContacts = {};
  final Map<String, List<PathSelection>> _attemptPathHistory = {};
  final Map<String, AckHashMapping> _ackHashToMessageId = {};
  final Map<String, List<int>> _expectedAckHashes = {};
  final List<_AckHistoryEntry> _ackHistory = [];
  final Map<String, List<String>> _sendQueue = {};
  final Set<String> _activeMessages = {};
  final Set<String> _resolvedMessages = {};
  final Map<String, String> _expectedHashToMessageId = {};

  RetryServiceConfig? _config;

  MessageRetryService();

  void initialize(RetryServiceConfig config) {
    _config = config;
  }

  void setMaxRetries(int value) {
    _maxRetries = value.clamp(2, 10);
  }

  /// Compute expected ACK hash using same algorithm as firmware:
  /// SHA256([timestamp(4)][attempt(1)][text][sender_pubkey(32)]) -> first 4 bytes
  static int computeExpectedAckHash(
    int timestampSeconds,
    int attempt,
    String text,
    Uint8List senderPubKey,
  ) {
    final textBytes = utf8.encode(text);
    final buffer = Uint8List(4 + 1 + textBytes.length + senderPubKey.length);
    int offset = 0;

    // timestamp (4 bytes, little-endian)
    buffer[offset++] = timestampSeconds & 0xFF;
    buffer[offset++] = (timestampSeconds >> 8) & 0xFF;
    buffer[offset++] = (timestampSeconds >> 16) & 0xFF;
    buffer[offset++] = (timestampSeconds >> 24) & 0xFF;

    // attempt (1 byte)
    buffer[offset++] = attempt & 0x03;

    // text
    buffer.setRange(offset, offset + textBytes.length, textBytes);
    offset += textBytes.length;

    // sender public key (32 bytes)
    buffer.setRange(offset, offset + senderPubKey.length, senderPubKey);

    // Compute SHA256 and return first 4 bytes
    final hash = sha256.convert(buffer);
    final bytes = Uint8List.fromList(hash.bytes.sublist(0, 4));
    return (bytes[3] << 24) | (bytes[2] << 16) | (bytes[1] << 8) | bytes[0];
  }

  Future<void> sendMessageWithRetry({
    required Contact contact,
    required String text,
    String? originalText,
    String? translatedLanguageCode,
    String? translationModelId,
    Uint8List? pathBytes,
    int? pathLength,
  }) async {
    final messageId = const Uuid().v4();
    final resolved = resolvePathSelection(contact);
    final messagePathBytes =
        pathBytes ?? Uint8List.fromList(resolved.pathBytes);
    final messagePathLength =
        pathLength ?? (resolved.useFlood ? -1 : resolved.hopCount);
    final message = Message(
      senderKey: contact.publicKey,
      text: text,
      originalText: originalText,
      translatedLanguageCode: translatedLanguageCode,
      translationModelId: translationModelId,
      timestamp: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.pending,
      messageId: messageId,
      retryCount: 0,
      pathLength: messagePathLength,
      pathBytes: messagePathBytes,
    );

    _pendingMessages[messageId] = message;
    _pendingContacts[messageId] = contact;

    _config?.addMessage(contact.publicKeyHex, message);

    // Queue per contact, only one message in-flight at a time to avoid
    // overflowing the firmware's 8-entry expected_ack_table.
    final contactKey = contact.publicKeyHex;
    _sendQueue[contactKey] ??= [];
    _sendQueue[contactKey]!.add(messageId);

    if (!_activeMessages.any(
      (id) => _pendingContacts[id]?.publicKeyHex == contactKey,
    )) {
      _sendNextForContact(contactKey);
    }
  }

  void _sendNextForContact(String contactKey) {
    final queue = _sendQueue[contactKey];
    if (queue == null) return;

    // Drain stale entries iteratively instead of recursing.
    while (queue.isNotEmpty) {
      final messageId = queue.removeAt(0);
      if (_pendingMessages.containsKey(messageId)) {
        _activeMessages.add(messageId);
        _attemptSend(messageId).catchError((e) {
          debugPrint('_attemptSend threw for $messageId: $e');
          final msg = _pendingMessages[messageId];
          if (msg != null) {
            final failed = msg.copyWith(status: MessageStatus.failed);
            _pendingMessages[messageId] = failed;
            _config?.updateMessage(failed);
          }
          _onMessageResolved(messageId, contactKey);
        });
        return;
      }
    }
  }

  void _onMessageResolved(String messageId, String contactKey) {
    if (_resolvedMessages.contains(messageId)) return;
    _resolvedMessages.add(messageId);
    _activeMessages.remove(messageId);
    _sendNextForContact(contactKey);
  }

  PathSelection? _selectPathForAttempt(Message message, Contact contact) {
    final config = _config;
    if (config == null) return null;
    final autoRotationEnabled =
        config.appSettingsService?.settings.autoRouteRotationEnabled == true;
    if (!autoRotationEnabled ||
        contact.pathOverride != null ||
        config.selectRetryPath == null) {
      return null;
    }

    final recentSelections = List<PathSelection>.from(
      _attemptPathHistory[message.messageId] ?? const <PathSelection>[],
    );
    return config.selectRetryPath!(
      contact.publicKeyHex,
      message.retryCount,
      maxRetries,
      recentSelections,
    );
  }

  void _recordAttemptPathHistory(String messageId, PathSelection selection) {
    if (selection.useFlood) return;
    final history = _attemptPathHistory.putIfAbsent(messageId, () => []);
    history.add(selection);
    if (history.length > recentAttemptDiversityWindow) {
      history.removeAt(0);
    }
  }

  Future<void> _attemptSend(String messageId) async {
    final message = _pendingMessages[messageId];
    final contact = _pendingContacts[messageId];
    final config = _config;

    if (message == null || contact == null || config == null) return;

    final currentSelection = _selectPathForAttempt(message, contact);

    if (currentSelection != null) {
      final updatedMessage = message.copyWith(
        pathLength: currentSelection.useFlood ? -1 : currentSelection.hopCount,
        pathBytes: currentSelection.useFlood
            ? Uint8List(0)
            : Uint8List.fromList(currentSelection.pathBytes),
      );
      _pendingMessages[messageId] = updatedMessage;
    } else if (message.retryCount > 0) {
      // No schedule entry for this retry, re-resolve path from current contact
      // state so user's path override changes are picked up between retries.
      final resolved = resolvePathSelection(contact);
      final updatedMessage = message.copyWith(
        pathLength: resolved.useFlood ? -1 : resolved.hopCount,
        pathBytes: Uint8List.fromList(resolved.pathBytes),
      );
      _pendingMessages[messageId] = updatedMessage;
    }

    // Re-read after potential schedule update
    final effectiveMessage = _pendingMessages[messageId] ?? message;

    // Sync path settings with device before sending
    if (config.setContactPath != null && config.clearContactPath != null) {
      final bool useFlood = currentSelection != null
          ? currentSelection.useFlood
          : (effectiveMessage.pathLength != null &&
                effectiveMessage.pathLength! < 0);
      final List<int> pathBytes = currentSelection != null
          ? currentSelection.pathBytes
          : effectiveMessage.pathBytes;
      final int hopCount = currentSelection != null
          ? currentSelection.hopCount
          : (effectiveMessage.pathLength ?? 0);

      if (useFlood) {
        await config.clearContactPath!(contact);
      } else if (effectiveMessage.pathLength != null) {
        await config.setContactPath!(
          contact,
          Uint8List.fromList(pathBytes),
          hopCount,
        );
      }
    }

    // Re-validate after async gap, a timer or ACK could have resolved/retried
    // this message while we were awaiting the path callback.
    final currentMessage = _pendingMessages[messageId];
    if (currentMessage == null || _resolvedMessages.contains(messageId)) {
      debugPrint(
        '_attemptSend: message $messageId resolved during path sync, aborting',
      );
      return;
    }
    if (currentMessage.retryCount != message.retryCount) {
      debugPrint(
        '_attemptSend: message $messageId retryCount changed during path sync, aborting',
      );
      return;
    }

    if (currentSelection != null) {
      _recordAttemptPathHistory(messageId, currentSelection);
    }

    final attempt = message.retryCount;
    final timestampSeconds = message.timestamp.millisecondsSinceEpoch ~/ 1000;

    // Compute expected ACK hash that device will return in RESP_CODE_SENT
    // IMPORTANT: Use the transformed text (with SMAZ encoding if enabled) to match device's hash
    final selfPubKey = config.getSelfPublicKey?.call();
    if (selfPubKey != null) {
      final outboundText =
          config.prepareContactOutboundText?.call(contact, message.text) ??
          message.text;
      final expectedHash = MessageRetryService.computeExpectedAckHash(
        timestampSeconds,
        attempt,
        outboundText,
        selfPubKey,
      );
      final expectedHashHex = expectedHash.toRadixString(16).padLeft(8, '0');
      _expectedHashToMessageId[expectedHashHex] = messageId;

      final shortText = message.text.length > 20
          ? '${message.text.substring(0, 20)}...'
          : message.text;
      config.debugLogService?.info(
        'Sent "$shortText" to ${contact.name} → expect ACK hash $expectedHashHex (attempt $attempt)',
        tag: 'AckHash',
      );
    }

    // Await so a send failure (e.g. an oversized BLE write) propagates to the
    // catchError in _sendNextForContact, which marks the message failed and
    // drains the per-contact queue instead of wedging it (#395).
    await config.sendMessage(contact, message.text, attempt, timestampSeconds);

    // The write reached the transport; now guard the window until the radio
    // returns RESP_CODE_SENT. If it never does (frame dropped on the wire), this
    // message would otherwise stay "active" forever and block the queue (#395).
    _startSentConfirmationTimer(messageId);
  }

  void _startSentConfirmationTimer(String messageId) {
    _sentConfirmationTimers[messageId]?.cancel();
    _sentConfirmationTimers[messageId] = Timer(
      const Duration(milliseconds: _sentConfirmationTimeoutMs),
      () => _handleSentConfirmationTimeout(messageId),
    );
  }

  void _handleSentConfirmationTimeout(String messageId) {
    _sentConfirmationTimers.remove(messageId);
    final message = _pendingMessages[messageId];
    final contact = _pendingContacts[messageId];
    if (message == null || contact == null) return;
    // RESP_CODE_SENT would have moved the status to sent (and cancelled this
    // timer); still-pending here means the radio never confirmed the send.
    if (message.status != MessageStatus.pending) return;

    final failed = message.copyWith(status: MessageStatus.failed);
    _pendingMessages[messageId] = failed;
    _config?.updateMessage(failed);
    _config?.debugLogService?.warn(
      'No RESP_CODE_SENT within ${_sentConfirmationTimeoutMs}ms, marking send failed',
      tag: 'AckHash',
    );
    notifyListeners();
    _onMessageResolved(messageId, contact.publicKeyHex);
  }

  /// Message ids whose send reached the radio but whose RESP_CODE_SENT has not
  /// arrived yet.
  List<String> get _sendsAwaitingConfirmation => _sentConfirmationTimers.keys
      .where((id) => _pendingMessages[id]?.status == MessageStatus.pending)
      .toList();

  /// The radio is authoritative for the expected-ACK hash it reports in
  /// RESP_CODE_SENT. Firmware forks build the message payload differently, so
  /// the hash recomputed locally can disagree while the send itself is fine.
  /// When that happened the message stayed pending, the 8s watchdog from #395
  /// marked an already-delivered DM failed, and the genuine ACK later matched
  /// nothing because every downstream map is only populated on the match path.
  /// Captured on a Wadamesh radio in #449.
  ///
  /// This frame is the reply to our own CMD_SEND_TXT_MSG, so adopt the radio's
  /// value when exactly one send is awaiting confirmation. With zero or several
  /// candidates the correlation would be a guess, so keep the old behaviour.
  ///
  /// [allowed] is false when a channel message is also awaiting its
  /// RESP_CODE_SENT. Channel sends share this frame, so adopting there could
  /// attach a channel message's confirmation to an unrelated direct message.
  String? _adoptUnpredictedSentHash(
    String ackHashHex,
    RetryServiceConfig config, {
    required bool allowed,
  }) {
    if (!allowed) {
      config.debugLogService?.warn(
        'RESP_CODE_SENT: ACK hash $ackHashHex matches no pending message and a '
        'channel send is also awaiting confirmation, not adopting',
        tag: 'AckHash',
      );
      return null;
    }

    final awaiting = _sendsAwaitingConfirmation;
    if (awaiting.length != 1) {
      config.debugLogService?.warn(
        'RESP_CODE_SENT: ACK hash $ackHashHex matches no pending message and '
        '${awaiting.length} sends are awaiting confirmation, ignoring',
        tag: 'AckHash',
      );
      return null;
    }

    final messageId = awaiting.first;
    final message = _pendingMessages[messageId];
    final text = message?.text ?? '';
    final shortText = text.length > 20 ? '${text.substring(0, 20)}...' : text;
    config.debugLogService?.warn(
      'RESP_CODE_SENT: ACK hash $ackHashHex is not the hash we predicted, '
      'adopting the radio value for "$shortText" (the radio is authoritative, '
      'see #449)',
      tag: 'AckHash',
    );

    // Drop the stale prediction so it cannot mis-match a later reply.
    _expectedHashToMessageId.removeWhere((_, id) => id == messageId);
    return messageId;
  }

  /// [allowUnpredictedAdoption] must be false when a channel message is also
  /// awaiting its RESP_CODE_SENT, because that frame could belong to either.
  bool updateMessageFromSent(
    int ackHash,
    int timeoutMs, {
    bool allowUnpredictedAdoption = true,
  }) {
    final config = _config;
    if (config == null) return false;

    final ackHashHex = ackHash.toRadixString(16).padLeft(8, '0');

    // Try hash-based matching (fixes LoRa message drops causing mismatches)
    String? messageId = _expectedHashToMessageId.remove(ackHashHex);
    Contact? contact;

    if (messageId != null) {
      contact = _pendingContacts[messageId];
      final message = _pendingMessages[messageId];

      if (contact != null && message != null) {
        final shortText = message.text.length > 20
            ? '${message.text.substring(0, 20)}...'
            : message.text;
        config.debugLogService?.info(
          'RESP_CODE_SENT received: ACK hash $ackHashHex ✓ matched "$shortText" to ${contact.name}',
          tag: 'AckHash',
        );
      } else {
        config.debugLogService?.warn(
          'RESP_CODE_SENT: ACK hash $ackHashHex matched but message no longer pending',
          tag: 'AckHash',
        );
        messageId = null;
        contact = null;
      }
    }

    if (messageId == null || contact == null) {
      final adopted = _adoptUnpredictedSentHash(
        ackHashHex,
        config,
        allowed: allowUnpredictedAdoption,
      );
      if (adopted == null) return false;
      messageId = adopted;
      contact = _pendingContacts[adopted];
      if (contact == null) return false;
    }

    final message = _pendingMessages[messageId]!;
    _ackHashToMessageId[ackHashHex] = (
      messageId: messageId,
      timestamp: DateTime.now(),
      attemptIndex: message.retryCount,
      pathSelection: _selectionFromMessage(message),
    );

    // Add this ACK hash to the list of expected ACKs for this message (for history)
    _expectedAckHashes[messageId] ??= [];
    if (!_expectedAckHashes[messageId]!.any((hash) => hash == ackHash)) {
      _expectedAckHashes[messageId]!.add(ackHash);
    }

    // Calculate timeout: prefer ML prediction, then device-provided, then physics fallback
    final pathLengthValue = message.pathLength ?? contact.pathLength;

    int actualTimeout = timeoutMs;
    if (config.calculateTimeout != null) {
      actualTimeout = config.calculateTimeout!(
        pathLengthValue,
        message.text.length,
        contactKey: contact.publicKeyHex,
      );
    }

    final updatedMessage = message.copyWith(
      status: MessageStatus.sent,
      expectedAckHash: ackHash,
      estimatedTimeoutMs: actualTimeout,
      sentAt: DateTime.now(),
    );

    _pendingMessages[messageId] = updatedMessage;
    config.updateMessage(updatedMessage);

    // Radio confirmed the send, the delivery-ack timer takes over from here.
    _sentConfirmationTimers.remove(messageId)?.cancel();
    _startTimeoutTimer(messageId, actualTimeout);
    return true;
  }

  bool get hasPendingMessages => _pendingMessages.isNotEmpty;

  /// Update the stored contact snapshot for all pending messages to this contact.
  /// Call this when the contact's pathOverride changes so retries use the new path.
  void updatePendingContact(Contact contact) {
    final keys = _pendingContacts.entries
        .where((e) => e.value.publicKeyHex == contact.publicKeyHex)
        .map((e) => e.key)
        .toList();
    for (final key in keys) {
      _pendingContacts[key] = contact;
    }
  }

  void _startTimeoutTimer(String messageId, int timeoutMs) {
    _timeoutTimers[messageId]?.cancel();
    _timeoutTimers[messageId] = Timer(Duration(milliseconds: timeoutMs), () {
      _handleTimeout(messageId);
    });
  }

  void _cleanupMessage(String messageId) {
    _moveAckHashesToHistory(messageId);
    _ackHashToMessageId.removeWhere(
      (_, mapping) => mapping.messageId == messageId,
    );
    _expectedHashToMessageId.removeWhere((_, msgId) => msgId == messageId);
    _pendingMessages.remove(messageId);
    _pendingContacts.remove(messageId);
    _attemptPathHistory.remove(messageId);
    _timeoutTimers.remove(messageId);
    _sentConfirmationTimers.remove(messageId)?.cancel();
    _resolvedMessages.remove(messageId);
  }

  void _handleTimeout(String messageId) {
    final message = _pendingMessages[messageId];
    final contact = _pendingContacts[messageId];
    final config = _config;
    final selection = message != null ? _selectionFromMessage(message) : null;

    if (message == null || contact == null) {
      debugPrint(
        'Timeout fired but message $messageId no longer pending (likely already delivered)',
      );
      return;
    }

    final shortText = message.text.length > 20
        ? '${message.text.substring(0, 20)}...'
        : message.text;
    config?.debugLogService?.warn(
      'Timeout: No ACK received for "$shortText" to ${contact.name} (attempt ${message.retryCount}) → retrying',
      tag: 'AckHash',
    );

    if (message.retryCount < maxRetries - 1) {
      final backoffMs = 1000 * (1 << message.retryCount);

      if (selection != null) {
        _recordPathResultFromMessage(
          contact.publicKeyHex,
          message,
          selection,
          false,
          null,
        );
      }

      final updatedMessage = message.copyWith(
        retryCount: message.retryCount + 1,
        status: MessageStatus.pending,
      );

      _pendingMessages[messageId] = updatedMessage;
      config?.updateMessage(updatedMessage);

      config?.debugLogService?.info(
        'Scheduling retry for "$shortText" to ${contact.name} after ${backoffMs}ms backoff',
        tag: 'AckHash',
      );

      _timeoutTimers[messageId] = Timer(Duration(milliseconds: backoffMs), () {
        if (_pendingMessages.containsKey(messageId)) {
          _attemptSend(messageId);
        }
      });
    } else {
      // Max retries reached - mark as failed
      final failedMessage = message.copyWith(status: MessageStatus.failed);
      _pendingMessages[messageId] = failedMessage;

      if (config?.appSettingsService?.settings.clearPathOnMaxRetry == true &&
          config?.clearContactPath != null) {
        config!.clearContactPath!(contact);
      }

      _recordPathResultFromMessage(
        contact.publicKeyHex,
        message,
        selection,
        false,
        null,
      );

      config?.updateMessage(failedMessage);

      notifyListeners();

      _onMessageResolved(messageId, contact.publicKeyHex);

      // Keep message in pending maps for 30s grace period so late ACKs
      // can still match and update the message to delivered.
      _timeoutTimers[messageId] = Timer(const Duration(seconds: 30), () {
        _cleanupMessage(messageId);
      });
    }
  }

  void _moveAckHashesToHistory(String messageId) {
    final ackHashes = _expectedAckHashes.remove(messageId);
    if (ackHashes != null && ackHashes.isNotEmpty) {
      _ackHistory.add(
        _AckHistoryEntry(
          messageId: messageId,
          ackHashes: ackHashes,
          timestamp: DateTime.now(),
        ),
      );

      while (_ackHistory.length > maxAckHistorySize) {
        _ackHistory.removeAt(0);
      }
    }
  }

  bool _checkAckHistory(int ackHash) {
    for (final entry in _ackHistory) {
      for (final expectedHash in entry.ackHashes) {
        if (expectedHash == ackHash) {
          return true;
        }
      }
    }
    return false;
  }

  void handleAckReceived(int ackHash, int tripTimeMs) {
    final config = _config;
    String? matchedMessageId;
    int? matchedAttemptIndex;
    PathSelection? matchedPathSelection;
    final ackHashHex = ackHash.toRadixString(16).padLeft(8, '0');

    // Clean up old ACK hash mappings (older than 15 minutes)
    final cutoffTime = DateTime.now().subtract(const Duration(minutes: 15));
    final hashesToRemove = <String>[];
    for (var entry in _ackHashToMessageId.entries) {
      if (entry.value.timestamp.isBefore(cutoffTime)) {
        hashesToRemove.add(entry.key);
      }
    }
    for (var hash in hashesToRemove) {
      _ackHashToMessageId.remove(hash);
    }

    // Use direct O(1) lookup via ACK hash mapping
    final mapping = _ackHashToMessageId[ackHashHex];
    if (mapping != null) {
      matchedMessageId = mapping.messageId;
      matchedAttemptIndex = mapping.attemptIndex;
      matchedPathSelection = mapping.pathSelection;
    } else {
      config?.debugLogService?.warn(
        'PUSH_CODE_SEND_CONFIRMED: ACK hash $ackHashHex not found in direct mapping, trying fallback',
        tag: 'AckHash',
      );
      // Fallback: Check against ALL expected ACK hashes (from all retry attempts)
      for (var entry in _expectedAckHashes.entries) {
        final messageId = entry.key;
        final expectedHashes = entry.value;

        for (final expectedHash in expectedHashes) {
          if (expectedHash == ackHash) {
            matchedMessageId = messageId;
            matchedAttemptIndex = expectedHashes.indexOf(expectedHash);
            break;
          }
        }

        if (matchedMessageId != null) break;
      }
    }

    if (matchedMessageId != null) {
      final message = _pendingMessages[matchedMessageId];
      if (message == null) {
        _ackHashToMessageId.remove(ackHashHex);
        return;
      }
      final contact = _pendingContacts[matchedMessageId];
      final ackedAttempt = matchedAttemptIndex ?? message.retryCount;
      final selection = matchedPathSelection ?? _selectionFromMessage(message);

      final shortText = message.text.length > 20
          ? '${message.text.substring(0, 20)}...'
          : message.text;
      config?.debugLogService?.info(
        'PUSH_CODE_SEND_CONFIRMED: ACK hash $ackHashHex ✓ "$shortText" delivered to ${contact?.name ?? "unknown"} on attempt $ackedAttempt in ${tripTimeMs}ms',
        tag: 'AckHash',
      );

      _timeoutTimers[matchedMessageId]?.cancel();

      final deliveredMessage = message.copyWith(
        status: MessageStatus.delivered,
        deliveredAt: DateTime.now(),
        tripTimeMs: tripTimeMs,
      );

      final wasAlreadyResolved = _resolvedMessages.contains(matchedMessageId);

      _cleanupMessage(matchedMessageId);

      config?.updateMessage(deliveredMessage);

      if (contact != null) {
        _recordPathResultFromMessage(
          contact.publicKeyHex,
          message,
          selection,
          true,
          tripTimeMs,
        );
        if (config?.onDeliveryObserved != null &&
            tripTimeMs > 0 &&
            message.pathLength != null) {
          config!.onDeliveryObserved!(
            contact.publicKeyHex,
            message.pathLength!,
            message.text.length,
            tripTimeMs,
          );
        }
        if (!wasAlreadyResolved) {
          _onMessageResolved(matchedMessageId, contact.publicKeyHex);
        }
      }

      notifyListeners();
    } else {
      if (_checkAckHistory(ackHash)) {
        config?.debugLogService?.info(
          'PUSH_CODE_SEND_CONFIRMED: ACK hash $ackHashHex matched a recently completed message (duplicate ACK)',
          tag: 'AckHash',
        );
      } else {
        config?.debugLogService?.error(
          'PUSH_CODE_SEND_CONFIRMED: ACK hash $ackHashHex has no matching message!',
          tag: 'AckHash',
        );
        debugPrint('No matching message found for ACK: $ackHashHex');
      }
    }
  }

  String? getContactKeyForAckHash(int ackHash) {
    for (var entry in _pendingMessages.entries) {
      final message = entry.value;
      if (message.expectedAckHash != null &&
          message.expectedAckHash == ackHash) {
        final contact = _pendingContacts[entry.key];
        return contact?.publicKeyHex;
      }
    }
    return null;
  }

  int calculateDefaultTimeout(Contact contact) {
    if (contact.pathLength < 0) {
      return 15000;
    } else {
      return 3000 + (3000 * contact.pathLength);
    }
  }

  void _recordPathResultFromMessage(
    String contactKey,
    Message message,
    PathSelection? selection,
    bool success,
    int? tripTimeMs,
  ) {
    final callback = _config?.recordPathResult;
    if (callback == null) return;
    final recordSelection = selection ?? _selectionFromMessage(message);
    if (recordSelection == null) return;
    callback(contactKey, recordSelection, success, tripTimeMs);
  }

  PathSelection? _selectionFromMessage(Message message) {
    if (message.pathLength != null && message.pathLength! < 0) {
      return const PathSelection(pathBytes: [], hopCount: -1, useFlood: true);
    }
    if (message.pathBytes.isEmpty && message.pathLength == null) {
      return null;
    }
    return PathSelection(
      pathBytes: message.pathBytes,
      hopCount: message.pathLength ?? message.pathBytes.length,
      useFlood: false,
    );
  }

  @override
  void dispose() {
    for (var timer in _timeoutTimers.values) {
      timer.cancel();
    }
    _timeoutTimers.clear();
    for (var timer in _sentConfirmationTimers.values) {
      timer.cancel();
    }
    _sentConfirmationTimers.clear();
    _pendingMessages.clear();
    _pendingContacts.clear();
    _attemptPathHistory.clear();
    _expectedAckHashes.clear();
    _ackHistory.clear();
    _ackHashToMessageId.clear();
    _sendQueue.clear();
    _activeMessages.clear();
    _resolvedMessages.clear();
    super.dispose();
  }
}
