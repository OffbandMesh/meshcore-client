import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/contact.dart';
import '../models/path_selection.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../utils/app_logger.dart';

/// A repeater reply that arrived with no command waiting to receive it.
///
/// [command] carries the original request when the reply could be traced back
/// to one that already timed out, and is null when the reply cannot be
/// attributed to anything this service sent.
class UnmatchedRepeaterResponse {
  final String repeaterKeyHex;
  final String response;
  final String? command;
  final Duration? sinceTimeout;

  const UnmatchedRepeaterResponse({
    required this.repeaterKeyHex,
    required this.response,
    this.command,
    this.sinceTimeout,
  });

  /// True when this answers a request that timed out rather than arriving
  /// unsolicited.
  bool get isLateReply => command != null;
}

class _ExpiredCommand {
  final String command;
  final DateTime expiredAt;

  const _ExpiredCommand({required this.command, required this.expiredAt});
}

class RepeaterCommandService {
  final MeshCoreConnector _connector;
  final Map<String, Completer<String>> _pendingCommands = {};
  final Map<String, Timer> _commandTimeouts = {};
  final Map<String, String> _commandPrefixes = {};
  final Map<String, String> _pendingByPrefix = {};
  final Map<String, _ExpiredCommand> _expiredCommands = {};
  int _prefixCounter = 0;

  static const int maxRetries = 5;

  /// How long a timed-out command stays remembered so a reply arriving after
  /// its window can still be presented with the request it answers.
  static const Duration lateReplyRetention = Duration(minutes: 2);

  /// Invoked when a reply cannot be handed to a waiting command. Consumers
  /// must surface this to the user: the reply is a real answer from the
  /// repeater and dropping it silently loses it for good (#528).
  void Function(UnmatchedRepeaterResponse)? onUnmatchedResponse;

  RepeaterCommandService(this._connector);

  /// Send a CLI command to a repeater with automatic retries
  /// Returns a future that completes when a response is received or after max retries
  Future<String> sendCommand(
    Contact repeater,
    String command, {
    Function(String)? onResponse,
    Function(int)? onAttempt,
    int retries = maxRetries,
  }) async {
    final attemptCount = retries < 1 ? 1 : retries;
    final selection = await _connector.preparePathForContactSend(repeater);
    final attemptPrefixes = <String>[];

    for (int attempt = 0; attempt < attemptCount; attempt++) {
      onAttempt?.call(attempt + 1);
      try {
        final response = await _sendCommandAttempt(
          repeater,
          command,
          selection,
          attempt,
          attemptPrefixes,
        );
        // The caller has its answer, so a straggler from an earlier attempt of
        // this same command is noise rather than a lost response.
        for (final prefix in attemptPrefixes) {
          _expiredCommands.remove(prefix);
        }
        onResponse?.call(response);
        return response;
      } catch (e) {
        if (attempt == attemptCount - 1) rethrow;
      }
    }

    throw Exception('Command failed after $attemptCount attempts');
  }

  Future<String> _sendCommandAttempt(
    Contact repeater,
    String command,
    PathSelection selection,
    int attempt,
    List<String> attemptPrefixes,
  ) async {
    final repeaterKey = repeater.publicKeyHex;
    final prefix = _nextPrefixToken();
    final commandId = '${repeaterKey}_$prefix';
    final completer = Completer<String>();
    _pendingCommands[commandId] = completer;
    _commandPrefixes[commandId] = prefix;
    _pendingByPrefix[prefix] = commandId;
    attemptPrefixes.add(prefix);

    try {
      final framedCommand = '$prefix$command';
      final pathLengthValue = selection.useFlood ? -1 : selection.hopCount;
      final timestampSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _connector.trackRepeaterAck(
        contact: repeater,
        selection: selection,
        text: framedCommand,
        timestampSeconds: timestampSeconds,
        attempt: attempt,
      );
      final frame = buildSendCliCommandFrame(
        repeater.publicKey,
        framedCommand,
        attempt: attempt,
        timestampSeconds: timestampSeconds,
      );
      final responseBytes = frame.length > maxFrameSize
          ? frame.length
          : maxFrameSize;
      final timeoutMs = _connector.calculateTimeout(
        pathLength: pathLengthValue,
        messageBytes: responseBytes,
      );
      final timeoutSeconds = (timeoutMs / 1000).ceil();
      await _connector.sendFrame(frame);
      _commandTimeouts[commandId]?.cancel();
      _commandTimeouts[commandId] = Timer(
        Duration(milliseconds: timeoutMs),
        () {
          final completer = _pendingCommands[commandId];
          if (completer != null && !completer.isCompleted) {
            // Remember what this prefix asked so a reply arriving after the
            // window can still reach the user with its question attached.
            _expiredCommands[prefix] = _ExpiredCommand(
              command: command,
              expiredAt: DateTime.now(),
            );
            completer.completeError(
              'Command timeout after $timeoutSeconds seconds',
            );
            _cleanup(commandId);
          }
        },
      );
    } catch (e) {
      _cleanup(commandId);
      throw Exception('Failed to send command: $e');
    }

    try {
      return await completer.future;
    } finally {
      _cleanup(commandId);
    }
  }

  /// Call this when a text message response is received from a repeater
  void handleResponse(Contact repeater, String responseText) {
    final repeaterKey = repeater.publicKeyHex;
    _pruneExpiredCommands();

    String? prefix;
    String responsePayload = responseText;
    if (responseText.length >= 3 && responseText[2] == '|') {
      prefix = responseText.substring(0, 3);
      responsePayload = responseText.substring(3).trimLeft();
    }

    final matchedId = prefix != null ? _pendingByPrefix[prefix] : null;
    final commandId =
        matchedId ??
        _pendingCommands.keys.firstWhere(
          (id) => id.startsWith(repeaterKey),
          orElse: () => '',
        );

    if (commandId.isNotEmpty) {
      final completer = _pendingCommands[commandId];
      if (completer != null && !completer.isCompleted) {
        completer.complete(responsePayload);
        _cleanup(commandId);
        return;
      }
    }

    // Nothing is waiting for this reply. It is still a real answer from the
    // repeater, so it gets surfaced and logged rather than dropped (#528).
    _surfaceUnmatchedResponse(repeaterKey, prefix, responsePayload);
  }

  void _surfaceUnmatchedResponse(
    String repeaterKey,
    String? prefix,
    String responsePayload,
  ) {
    final expired = prefix != null ? _expiredCommands.remove(prefix) : null;
    final sinceTimeout = expired == null
        ? null
        : DateTime.now().difference(expired.expiredAt);

    if (expired != null) {
      appLogger.warn(
        'Late reply to "${expired.command}" from $repeaterKey arrived '
        '${sinceTimeout!.inMilliseconds}ms after its window closed',
        tag: 'RepeaterCommand',
      );
    } else {
      appLogger.warn(
        'Reply from $repeaterKey matched no pending or recently expired '
        'command (prefix: ${prefix ?? 'none'})',
        tag: 'RepeaterCommand',
      );
    }

    onUnmatchedResponse?.call(
      UnmatchedRepeaterResponse(
        repeaterKeyHex: repeaterKey,
        response: responsePayload,
        command: expired?.command,
        sinceTimeout: sinceTimeout,
      ),
    );
  }

  /// Records a timed-out command so a reply arriving later can still be
  /// attributed to it. Exposed because a test cannot drive a real
  /// send-then-time-out cycle without a connected transport.
  @visibleForTesting
  void recordExpiredCommandForTest(String prefix, String command) {
    _expiredCommands[prefix] = _ExpiredCommand(
      command: command,
      expiredAt: DateTime.now(),
    );
  }

  void _pruneExpiredCommands() {
    if (_expiredCommands.isEmpty) return;
    final cutoff = DateTime.now().subtract(lateReplyRetention);
    _expiredCommands.removeWhere(
      (_, entry) => entry.expiredAt.isBefore(cutoff),
    );
  }

  void _cleanup(String commandId) {
    _commandTimeouts[commandId]?.cancel();
    _commandTimeouts.remove(commandId);
    _pendingCommands.remove(commandId);
    final prefix = _commandPrefixes.remove(commandId);
    if (prefix != null) {
      _pendingByPrefix.remove(prefix);
    }
  }

  void dispose() {
    for (final timer in _commandTimeouts.values) {
      timer.cancel();
    }
    _commandTimeouts.clear();
    _pendingCommands.clear();
    _commandPrefixes.clear();
    _pendingByPrefix.clear();
    _expiredCommands.clear();
    onUnmatchedResponse = null;
  }

  String _nextPrefixToken() {
    for (var i = 0; i < 256; i++) {
      final value = _prefixCounter++ & 0xFF;
      final token = '${value.toRadixString(16).padLeft(2, '0').toUpperCase()}|';
      if (!_pendingByPrefix.containsKey(token)) {
        return token;
      }
    }
    return '00|';
  }
}
