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

  void _onFrame(Uint8List frame) {
    if (_disposed || frame.isEmpty) return;
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
    // retries: 1 - one send, no auto-retry. See the file header.
    try {
      final text = await _service.sendCommand(
        _resolveTarget(),
        command,
        retries: 1,
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
    _service.dispose();
  }
}
