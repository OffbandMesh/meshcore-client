import 'dart:convert';
import 'dart:typed_data';

import '../connector/cli_command_codec.dart';
import '../connector/meshcore_protocol.dart';
import '../connector/observer_config_client.dart';
import '../connector/offband_device_ui.dart';

/// What a frame the app sends carries that must not reach a log.
enum SentSecret {
  none,
  loginPassword,
  devicePin,
  privateKey,
  textMessage,
  cliCommand,
  config,
}

/// Every code the app can send, classified (#1192). A code missing here fails
/// `test/utils/log_redactor_inventory_test.dart`, and if one is sent anyway its
/// whole payload is blanked.
const Map<int, SentSecret> sentFrameSecrets = {
  cmdAppStart: SentSecret.none,
  cmdSendTxtMsg: SentSecret.textMessage,
  cmdSendChannelTxtMsg: SentSecret.none,
  cmdGetContacts: SentSecret.none,
  cmdGetDeviceTime: SentSecret.none,
  cmdSetDeviceTime: SentSecret.none,
  cmdSendSelfAdvert: SentSecret.none,
  cmdSetAdvertName: SentSecret.none,
  cmdAddUpdateContact: SentSecret.none,
  cmdSyncNextMessage: SentSecret.none,
  cmdSetRadioParams: SentSecret.none,
  cmdSetRadioTxPower: SentSecret.none,
  cmdResetPath: SentSecret.none,
  cmdSetAdvertLatLon: SentSecret.none,
  cmdRemoveContact: SentSecret.none,
  cmdShareContact: SentSecret.none,
  cmdExportContact: SentSecret.none,
  cmdImportContact: SentSecret.none,
  cmdReboot: SentSecret.none,
  cmdGetBattAndStorage: SentSecret.none,
  cmdDeviceQuery: SentSecret.none,
  cmdExportPrivateKey: SentSecret.none,
  cmdImportPrivateKey: SentSecret.privateKey,
  cmdSendLogin: SentSecret.loginPassword,
  cmdSendStatusReq: SentSecret.none,
  cmdGetContactByKey: SentSecret.none,
  cmdGetChannel: SentSecret.none,
  cmdSetChannel: SentSecret.none,
  cmdSendTracePath: SentSecret.none,
  cmdSetDevicePin: SentSecret.devicePin,
  cmdSetOtherParams: SentSecret.none,
  cmdSendTelemetryReq: SentSecret.none,
  cmdGetCustomVar: SentSecret.none,
  cmdSetCustomVar: SentSecret.none,
  cmdSendBinaryReq: SentSecret.none,
  cmdFactoryReset: SentSecret.none,
  cmdSetFloodScopeKey: SentSecret.none,
  cmdGetStats: SentSecret.none,
  cmdSendAnonReq: SentSecret.none,
  cmdSetAutoAddConfig: SentSecret.none,
  cmdGetAutoAddConfig: SentSecret.none,
  cmdSetPathHashMode: SentSecret.none,
  cmdSetDefaultFloodScope: SentSecret.none,
  cmdGetDefaultFloodScope: SentSecret.none,
  cmdRunCliCommand: SentSecret.cliCommand,
  ObserverConfigClient.cmdConfig: SentSecret.config,
  cmdOffbandGps: SentSecret.none,
  cmdOffbandBlock: SentSecret.none,
  cmdOffbandFemLna: SentSecret.none,
  cmdOffbandCaplog: SentSecret.none,
  cmdOffbandDeviceUi: SentSecret.none,
  cmdOffbandPktHash: SentSecret.none,
};

/// The radio's private key keeps this many leading bytes in a log; the rest
/// are blanked (owner decision, #1190).
const int keptPrivateKeyBytes = 3;

/// Byte a redacted byte becomes: `*`, so offsets and lengths survive.
const int redactedByte = 0x2A;

const _secretKey = r'[\w.]*(?:password|pwd|secret)';
final _cliSet = RegExp(
  '^(\\s*(?:set\\s+(?:$_secretKey|pin)|password)\\s+)(\\S.*)\$',
  caseSensitive: false,
  dotAll: true,
);
final _cliGet = RegExp(
  '^\\s*get\\s+(?:$_secretKey|pin)\\s*\$',
  caseSensitive: false,
);
final _passwordEcho = RegExp(r'password now:\s*', caseSensitive: false);
final _configSet = RegExp(
  '^($_secretKey )(.+)\$',
  caseSensitive: false,
  dotAll: true,
);
final _configReply = RegExp(
  '^($_secretKey\\s*=\\s*)(.+)\$',
  caseSensitive: false,
  dotAll: true,
);

/// Removes passwords and PINs from what the app logs (#1192). Everything else
/// is kept byte for byte: channel keys stay, and incoming codes the app does
/// not know stay raw (owner decisions on #1190).
///
/// Stateful only for `get <secret>` CLI commands, whose reply carries the
/// value with no key. A reply is paired with its command the way the device
/// pairs them: by the `cc|` prefix it reflects, or for commands sent without
/// one, in the order they were sent. Feed it every logged frame in order,
/// both directions.
///
/// Every secret is the last field of its frame, so redaction runs to the end
/// of the frame: a NUL inside a secret cannot leave its tail behind.
class LogRedactor {
  LogRedactor({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const Duration secretReplyWindow = Duration(seconds: 60);

  final DateTime Function() _now;
  final Map<String, DateTime> _secretPrefixes = {};
  final List<({bool secret, DateTime at})> _unprefixed = [];

  Uint8List frame(Uint8List frame, {required bool outgoing}) {
    final out = Uint8List.fromList(frame);
    if (out.isEmpty) return out;
    outgoing ? _sent(out) : _received(out);
    return out;
  }

  void _sent(Uint8List f) {
    switch (sentFrameSecrets[f[0]]) {
      case null:
        _blank(f, 1, f.length);
      case SentSecret.none:
        break;
      case SentSecret.loginPassword:
        _blankText(f, 33);
      case SentSecret.devicePin:
        _blank(f, 1, 5);
      case SentSecret.privateKey:
        _blank(f, 1 + keptPrivateKeyBytes, 1 + privateKeySize);
      case SentSecret.textMessage:
        if (f.length > 13 && _isCli(f[1])) _cliCommand(f, 13);
      case SentSecret.cliCommand:
        _cliCommand(f, 1);
      case SentSecret.config:
        if (f.length > 2 && f[1] == ObserverConfigClient.opSet) {
          _redactMatch(f, 2, _configSet);
        }
    }
  }

  void _received(Uint8List f) {
    switch (f[0]) {
      case respCodePrivateKey:
        _blank(f, 1 + keptPrivateKeyBytes, 1 + privateKeySize);
      case respCodeDeviceInfo:
        _blank(f, 4, 8);
      case respCodeContactMsgRecv:
        if (f.length > 13 && _isCli(f[8])) _cliReply(f, 13);
      case respCodeContactMsgRecvV3:
        if (f.length > 16 && _isCli(f[11])) _cliReply(f, 16);
      case respCodeCliReply:
        _cliReply(f, 1);
      case ObserverConfigClient.respConfig:
        if (f.length > 2 && f[1] == ObserverConfigClient.rValue) {
          _redactConfigReply(f, 2);
        } else if (f.length > 3 && f[1] == ObserverConfigClient.rBrokerKv) {
          _redactConfigReply(f, 3);
        }
    }
  }

  static bool _isCli(int txtType) {
    for (final t in [txtType, txtType >> 2]) {
      if (t == txtTypeCliData || t == txtTypeCliCommand) return true;
    }
    return false;
  }

  void _cliCommand(Uint8List f, int start) {
    final text = _text(f, start);
    final prefix = _prefixOf(text);
    final body = _stripPrefix(text);
    final secretGet = _cliGet.hasMatch(body);
    _expireGets();
    if (prefix == null) {
      _unprefixed.add((secret: secretGet, at: _now()));
    } else if (secretGet) {
      _secretPrefixes[prefix] = _now();
    }
    if (secretGet) return;
    _redactMatchAt(f, start + text.length - body.length, body, _cliSet);
  }

  void _cliReply(Uint8List f, int start) {
    final text = _text(f, start);
    final prefix = _prefixOf(text);
    _expireGets();
    final bool secret;
    if (prefix != null) {
      secret = _secretPrefixes.remove(prefix) != null;
    } else {
      secret = _unprefixed.isNotEmpty && _unprefixed.removeAt(0).secret;
    }
    if (secret) {
      _blankText(f, start + (prefix?.length ?? 0));
      return;
    }
    final echo = _passwordEcho.firstMatch(text);
    if (echo != null) _blankText(f, start + echo.end);
  }

  void _redactConfigReply(Uint8List f, int start) {
    final text = _text(f, start);
    final m = _configReply.firstMatch(text);
    if (m == null) return;
    final value = m.group(2)!.trim();
    if (value == '(set)' || value == '(unset)') return;
    _blankText(f, start + m.group(1)!.length);
  }

  void _redactMatch(Uint8List f, int start, RegExp pattern) =>
      _redactMatchAt(f, start, _text(f, start), pattern);

  static void _redactMatchAt(
    Uint8List f,
    int start,
    String text,
    RegExp pattern,
  ) {
    final m = pattern.firstMatch(text);
    if (m == null) return;
    _blankText(f, start + m.group(1)!.length);
  }

  void _expireGets() {
    final cutoff = _now().subtract(secretReplyWindow);
    _secretPrefixes.removeWhere((_, at) => at.isBefore(cutoff));
    _unprefixed.removeWhere((g) => g.at.isBefore(cutoff));
  }

  /// Latin-1 so each character is one byte and string offsets are frame
  /// offsets. Stops at the first NUL.
  static String _text(Uint8List f, int start) {
    if (start >= f.length) return '';
    var end = start;
    while (end < f.length && f[end] != 0) {
      end++;
    }
    return latin1.decode(f.sublist(start, end));
  }

  static String? _prefixOf(String text) =>
      text.length >= 3 && text[2] == '|' ? text.substring(0, 3) : null;

  static String _stripPrefix(String text) =>
      _prefixOf(text) == null ? text : text.substring(3);

  static void _blank(Uint8List f, int start, int end) {
    final stop = end < f.length ? end : f.length;
    for (var i = start; i < stop; i++) {
      f[i] = redactedByte;
    }
  }

  /// A text secret through to the end of the frame, keeping the frame's
  /// closing NUL so the logged text still reads as text.
  static void _blankText(Uint8List f, int start) =>
      _blank(f, start, f.isNotEmpty && f.last == 0 ? f.length - 1 : f.length);

  static final _frameLine = RegExp(
    r'^(\S+ (TX|RX) .*?  )((?:[0-9a-f]{2} )*[0-9a-f]{2})$',
    caseSensitive: false,
  );
  static final _lateReply = RegExp(
    r'^(.*Late reply to ")(.*)(" from .* after its window closed: )(.*)$',
    dotAll: true,
  );
  static final _strayReply = RegExp(
    r'^(.*matched no pending or recently expired command \(prefix: [^)]*\): )(.*)$',
    dotAll: true,
  );

  /// One line of a log file written before this redactor existed. Frame
  /// lines are decoded and redacted like a live frame, and the repeater
  /// reply lines get their CLI text redacted. Already-redacted lines come out
  /// unchanged. Feed a file's lines in order, oldest file first.
  String line(String text) {
    final f = _frameLine.firstMatch(text);
    if (f != null) {
      final bytes = Uint8List.fromList([
        for (final h in f.group(3)!.split(' ')) int.parse(h, radix: 16),
      ]);
      final out = frame(bytes, outgoing: f.group(2) == 'TX');
      return f.group(1)! +
          out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    }
    final late = _lateReply.firstMatch(text);
    if (late != null) {
      final command = late.group(2)!;
      return late.group(1)! +
          cliCommandText(command) +
          late.group(3)! +
          cliReplyText(command, late.group(4)!);
    }
    final stray = _strayReply.firstMatch(text);
    if (stray != null) {
      return stray.group(1)! + cliReplyText(null, stray.group(2)!);
    }
    return text;
  }

  /// A CLI command as logged in text: the value of a secret `set` or a
  /// `password` command becomes `*`s.
  static String cliCommandText(String command) {
    final m = _cliSet.firstMatch(command);
    if (m == null) return command;
    return m.group(1)! + '*' * m.group(2)!.length;
  }

  /// A CLI reply as logged in text. A reply to `get <secret>` is blanked
  /// whole, and a `password now: <new>` echo loses the password.
  static String cliReplyText(String? command, String reply) {
    if (command != null && _cliGet.hasMatch(_stripPrefix(command))) {
      return '*' * reply.length;
    }
    final echo = _passwordEcho.firstMatch(reply);
    if (echo == null) return reply;
    return reply.substring(0, echo.end) + '*' * (reply.length - echo.end);
  }
}
