// Local device CLI over frame 66/29 (#882, plan F2/E2.1). Sends
// CMD_RUN_CLI_COMMAND to the CONNECTED radio and completes with the
// correlated RESP_CODE_CLI_REPLY. No mesh legs, so no retries: the transport
// is the connected link, and a lost frame surfaces as a timeout.
//
// Population gating is NOT here: callers (the console entry point, #884)
// must only construct/offer this where the classifier allows frame 66.

import 'dart:async';

import '../connector/cli_command_codec.dart';
import '../connector/meshcore_connector.dart';
import '../utils/app_logger.dart';
import 'command_correlation.dart';

/// Thrown when the device does not answer inside the window.
class LocalCliTimeout implements Exception {
  const LocalCliTimeout({required this.command, required this.timeout});

  final String command;
  final Duration timeout;

  /// The armed window in seconds to one decimal, e.g. `10.0` - same shape as
  /// [RepeaterCommandTimeout.secondsText] so UI strings read alike.
  String get secondsText => (timeout.inMilliseconds / 1000).toStringAsFixed(1);

  @override
  String toString() => 'CLI command timed out after $secondsText s';
}

class LocalCliService {
  LocalCliService(this._connector) {
    _detach = _connector.addCliReplyListenerForLocalCli(_handleReply);
  }

  final MeshCoreConnector _connector;
  final PrefixAllocator _prefixes = PrefixAllocator();
  final Map<String, Completer<CliReply>> _pending = {};
  final Map<String, Timer> _timeouts = {};
  void Function()? _detach;

  /// Default window for a local round trip. Generous: some device handlers
  /// (WiFi status on a busy radio) run tens of milliseconds, and BLE
  /// notification scheduling adds more; nothing on the local link should
  /// legitimately take longer than this.
  static const Duration defaultTimeout = Duration(seconds: 10);

  /// Sends [command] to the connected device; completes with the correlated
  /// reply or throws [LocalCliTimeout] / [ArgumentError] (codec rejections).
  Future<CliReply> run(String command, {Duration? timeout}) async {
    final window = timeout ?? defaultTimeout;
    final prefix = _prefixes.next(_pending.keys.toSet());
    final frame = buildRunCliCommandFrame(command, prefix: prefix);

    final completer = Completer<CliReply>();
    _pending[prefix] = completer;
    _timeouts[prefix] = Timer(window, () {
      final waiting = _pending.remove(prefix);
      _timeouts.remove(prefix);
      if (waiting != null && !waiting.isCompleted) {
        waiting.completeError(
          LocalCliTimeout(command: command, timeout: window),
        );
      }
    });

    try {
      await _connector.sendFrame(frame);
    } catch (e) {
      _cleanup(prefix);
      rethrow;
    }

    try {
      return await completer.future;
    } finally {
      _cleanup(prefix);
    }
  }

  void _handleReply(CliReply reply) {
    final prefix = reply.prefix;
    final waiting = prefix != null ? _pending.remove(prefix) : null;
    if (waiting != null && !waiting.isCompleted) {
      _timeouts.remove(prefix)?.cancel();
      waiting.complete(reply);
      return;
    }
    // Every command this service sends carries a prefix, so an unmatched or
    // prefixless reply answers something that already timed out (or another
    // sender). Log it - never guess it onto a waiting command (#532's rule).
    // The reply TEXT is withheld: a late reply to a secret command (e.g.
    // `get wifi.pwd`) would otherwise write cleartext to the app log, which the
    // screen's masking cannot undo (Gemini review, #883). The correlation token
    // and byte length carry the debug value without the content.
    appLogger.warn(
      'CLI reply matched no pending command '
      '(prefix: ${prefix ?? 'none'}, ${reply.payloadLength} bytes); '
      'text withheld',
      tag: 'LocalCli',
    );
  }

  void _cleanup(String prefix) {
    _timeouts.remove(prefix)?.cancel();
    _pending.remove(prefix);
  }

  void dispose() {
    _detach?.call();
    _detach = null;
    for (final t in _timeouts.values) {
      t.cancel();
    }
    _timeouts.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          const LocalCliTimeout(command: '(disposed)', timeout: Duration.zero),
        );
      }
    }
    _pending.clear();
  }
}
