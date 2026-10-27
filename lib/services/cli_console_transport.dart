// What the CLI console (device_cli_screen) talks to (#999, plan F3/E3.1). The
// console renders the same transcript whether the CLI runs on the connected
// radio (local frame 66/29) or on a remote contact over the mesh (TXT type
// chosen by role, #888/#889). This abstracts the two transports behind one
// run()->CliReply call and one timeout type, so the screen holds no
// transport-specific branches.
//
// No auto-retry on the remote leg: a companion that has not granted us remote
// CLI (contact flag 0x10 on its side) queues our command as a plain message and
// never replies, so retrying only spams the mesh. One send, then a timeout the
// console explains (#891). Repeaters use their own screen and keep their retry
// behavior there.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../connector/cli_command_codec.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import 'local_cli_service.dart';
import 'repeater_command_service.dart';

/// A CLI command's window closed with no reply, regardless of transport. Both
/// underlying services carry their own timeout type; the console catches only
/// this one so its handling reads the same for a local or a remote command.
class CliConsoleTimeout implements Exception {
  const CliConsoleTimeout({required this.command, required this.secondsText});

  final String command;

  /// The armed window in seconds to one decimal, e.g. `10.0`.
  final String secondsText;

  @override
  String toString() => 'CLI command timed out after $secondsText s';
}

/// The connected radio refused to send a remote CLI command at all: its
/// firmware does not accept TXT_TYPE_CLI_COMMAND (pre-1.18 answers
/// ERR_CODE_UNSUPPORTED_CMD). Distinct from [CliConsoleTimeout], which means
/// the command went out and the target never answered.
class CliConsoleUnsupported implements Exception {
  const CliConsoleUnsupported({required this.command});

  final String command;

  @override
  String toString() => 'The connected radio does not support remote CLI';
}

/// One CLI transport for the console: the connected device, or a remote contact.
abstract class CliConsoleTransport {
  /// Runs [command] and completes with the correlated reply, or throws
  /// [CliConsoleTimeout] when the window closes with no answer. Other failures
  /// (codec rejection, send error) surface as their own exceptions.
  Future<CliReply> run(String command, {Duration? timeout});

  void dispose();
}

/// CLI on the connected radio, over frame 66/29.
class LocalCliTransport implements CliConsoleTransport {
  LocalCliTransport(MeshCoreConnector connector, {LocalCliService? service})
    : _service = service ?? LocalCliService(connector);

  final LocalCliService _service;

  @override
  Future<CliReply> run(String command, {Duration? timeout}) async {
    try {
      return await _service.run(command, timeout: timeout);
    } on LocalCliTimeout catch (e) {
      throw CliConsoleTimeout(command: command, secondsText: e.secondsText);
    }
  }

  @override
  void dispose() => _service.dispose();
}

/// CLI on a remote contact over the mesh. The txt type is chosen by the
/// target's role (#888/#889): a companion gets TXT_TYPE_CLI_COMMAND, a
/// repeater/room server the universal CLI_DATA. The reply returns as a contact
/// message carrying the reflected `cc|` prefix; this listens for it and feeds it
/// to the shared correlation in [RepeaterCommandService].
class RemoteCliTransport implements CliConsoleTransport {
  RemoteCliTransport(
    this._connector,
    this._target, {
    RepeaterCommandService? service,
  }) : _service = service ?? RepeaterCommandService(_connector) {
    // A companion is a human chat node, so a late/unmatched reply must never
    // log its text: a slow `get wifi.pwd` round trip would otherwise write the
    // password to the app log, which the console's masking cannot undo. Match
    // LocalCliService, which always withholds (#999 review).
    _service.redactUnmatchedReplyText = true;
    _sub = _connector.receivedFrames.listen(_onFrame);
  }

  final MeshCoreConnector _connector;
  final Contact _target;
  final RepeaterCommandService _service;
  StreamSubscription<Uint8List>? _sub;
  bool _disposed = false;

  /// Rejection channel for the command in flight: completed with
  /// [CliConsoleUnsupported] when the radio refuses the send outright.
  ///
  /// It only listens while [_armed]: from the moment the text frame is written
  /// (the `onAttempt` hook fires after the path update and runs straight into
  /// the frame write, with no yield in between) until the radio answers that
  /// write. The firmware answers each CMD_SEND_TXT_MSG at once, in order: a
  /// pre-1.18 radio with ERR_CODE_UNSUPPORTED_CMD for type 3; a 1.18 radio with
  /// RESP_CODE_SENT carrying an expected-ack of 0, since a CLI command expects
  /// no ack (companion-v1.18.0 CMD_SEND_TXT_MSG). A plain DM's SENT carries a
  /// real ack hash, so it never closes the window.
  ///
  /// ERR_CODE_UNSUPPORTED_CMD is also the firmware's answer to any unknown
  /// command. Arming at the write, rather than at [run], keeps an unrelated
  /// refusal from failing a valid command. The residual exposure is one
  /// landing inside our own send's round trip, on a radio where the connector
  /// already withholds fork frames.
  ///
  /// One command at a time: a new [run] replaces the channel, and the replaced
  /// command falls back to its timeout rather than risk misattribution.
  Completer<CliReply>? _sendWindow;
  String? _sendWindowCommand;
  bool _armed = false;

  void _onFrame(Uint8List frame) {
    if (_disposed || frame.isEmpty) return;
    if (frame[0] == respCodeSent) {
      // [RESP_CODE_SENT][is_flood][expected_ack x4][est_timeout x4]. Only a
      // command send's SENT (ack 0) answers ours.
      if (_armed &&
          frame.length >= 6 &&
          frame[2] == 0 &&
          frame[3] == 0 &&
          frame[4] == 0 &&
          frame[5] == 0) {
        _armed = false;
      }
      return;
    }
    if (frame[0] == respCodeErr) {
      final code = frame.length > 1 ? frame[1] : -1;
      final window = _sendWindow;
      if (_armed &&
          code == errCodeUnsupportedCmd &&
          window != null &&
          !window.isCompleted) {
        _armed = false;
        window.completeError(
          CliConsoleUnsupported(command: _sendWindowCommand ?? ''),
        );
      }
      return;
    }
    if (frame[0] != respCodeContactMsgRecv &&
        frame[0] != respCodeContactMsgRecvV3) {
      return;
    }
    final parsed = parseContactMessageText(frame);
    if (parsed == null) return;
    if (!_matchesTargetPrefix(parsed.senderPrefix)) return;
    // Only a CLI_DATA reply answers a command. A plain chat message, or an
    // inbound type-3 command, from the SAME companion must not complete our
    // pending command - without this it would hit handleResponse's unprefixed
    // sole-pending fallback and render "hey, you there?" as the CLI reply
    // (#999 review). Some layouts carry the type shifted; check both.
    final t = parsed.txtType;
    if (t != txtTypeCliData && (t >> 2) != txtTypeCliData) return;
    // Routes to the waiting command's future (or is logged if its window
    // already closed, #589). handleResponse resolves the target from its key,
    // so the possibly-stale [_target] is fine here.
    _service.handleResponse(_resolveTarget(), parsed.text);
  }

  bool _matchesTargetPrefix(Uint8List prefix) {
    final key = _target.publicKey;
    if (key.length < 6 || prefix.length < 6) return false;
    for (var i = 0; i < 6; i++) {
      if (prefix[i] != key[i]) return false;
    }
    return true;
  }

  /// The contact's path can be updated after this transport is built, so re-read
  /// the live contact by key at send time and fall back to the original.
  Contact _resolveTarget() {
    for (final c in _connector.contacts) {
      if (c.publicKeyHex == _target.publicKeyHex) return c;
    }
    return _target;
  }

  @override
  Future<CliReply> run(String command, {Duration? timeout}) async {
    final window = Completer<CliReply>();
    _sendWindow = window;
    _sendWindowCommand = command;
    _armed = false;
    try {
      // Whichever lands first: the reply (or its timeout), or the radio
      // refusing the send. Future.any keeps handlers on the loser, so its later
      // timeout is absorbed rather than surfacing as an unhandled error.
      return await Future.any([_send(command, window), window.future]);
    } finally {
      if (identical(_sendWindow, window)) {
        _sendWindow = null;
        _armed = false;
      }
    }
  }

  Future<CliReply> _send(String command, Completer<CliReply> window) async {
    // retries: 1 - one send, no auto-retry. See the file header.
    try {
      final text = await _service.sendCommand(
        _resolveTarget(),
        command,
        retries: 1,
        // Fires after the path update, immediately before the text frame is
        // written: arm the rejection window here, not earlier.
        onAttempt: (_) {
          if (identical(_sendWindow, window)) _armed = true;
        },
      );
      // payloadLength drives CliReply.atReplyBound (the local 165-byte device
      // bound). A remote reply is a reassembled mesh message, so that bound is
      // not meaningful and truncation cannot be detected here; the stripped
      // text length keeps atReplyBound false rather than faking a cut (#999).
      return CliReply(
        prefix: null,
        text: text,
        payloadLength: utf8.encode(text).length,
      );
    } on RepeaterCommandTimeout catch (e) {
      throw CliConsoleTimeout(command: command, secondsText: e.secondsText);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    // Release a command still waiting, so its run() cannot hang.
    final window = _sendWindow;
    _sendWindow = null;
    _armed = false;
    if (window != null && !window.isCompleted) {
      window.completeError(StateError('RemoteCliTransport disposed'));
    }
    _service.dispose();
  }
}
