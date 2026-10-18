// Codec for the upstream 1.18 companion CLI frames (interop plan F2, #868):
// CMD_RUN_CLI_COMMAND (66) out, RESP_CODE_CLI_REPLY (29) back. Pure codec,
// no transport — mirrors the firmware contract at companion-v1.18.0
// (INVESTIGATION.md §A1):
//   request  [66][ascii command], frame length >= 3
//   reply    [29][ascii reply], reply text <= 165 bytes (reply_buf[166])
// Correlation rides the optional 3-char prefix `cc|`: a command whose third
// character is `|` (and length > 4 on the device) has those 3 chars reflected
// at the start of the reply. Same grammar the repeater CLI already uses.
//
// Only emit frame 66 to a device the population classifier places at
// stockModern (or post-absorb Offband, via the D1 seam) — see
// device_population.dart. The codec itself does not gate.

import 'dart:convert';
import 'dart:typed_data';

/// `CMD_RUN_CLI_COMMAND`, stock v14+.
const int cmdRunCliCommand = 66;

/// `RESP_CODE_CLI_REPLY`, the reply to [cmdRunCliCommand].
const int respCodeCliReply = 29;

/// The device truncates replies at this many text bytes (`reply_buf[166]`,
/// one byte spent on the frame code).
const int maxCliReplyPayload = 165;

final RegExp _prefixShape = RegExp(r'^..\|$');

/// Builds a `[66][command]` frame, optionally prepending a 3-char
/// correlation [prefix] of the `cc|` shape.
///
/// Throws [ArgumentError] on a blank command, a command too short for the
/// firmware's `len >= 3` floor (two command bytes minimum), or a prefix that
/// is not exactly three characters ending in `|` — fail closed rather than
/// emit a frame the device will misparse.
Uint8List buildRunCliCommandFrame(String command, {String? prefix}) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(command, 'command', 'must not be blank');
  }
  if (prefix != null && !_prefixShape.hasMatch(prefix)) {
    throw ArgumentError.value(prefix, 'prefix', 'must be 3 chars ending in |');
  }
  final payload = '${prefix ?? ''}$trimmed';
  if (payload.length < 2) {
    throw ArgumentError.value(
      command,
      'command',
      'firmware requires at least 2 command bytes (frame len >= 3)',
    );
  }
  // The device CLI is an ASCII surface; encode fail-closed so a non-ASCII
  // command throws here instead of reaching the device malformed (Gemini
  // review, #881 finding 1).
  final List<int> bytes;
  try {
    bytes = ascii.encode(payload);
  } on ArgumentError {
    throw ArgumentError.value(command, 'command', 'must be ASCII');
  }
  return Uint8List.fromList([cmdRunCliCommand, ...bytes]);
}

/// One decoded CLI reply.
class CliReply {
  const CliReply({
    required this.prefix,
    required this.text,
    required this.payloadLength,
  });

  /// The reflected `cc|` correlation token, when the reply carries one.
  final String? prefix;

  /// Reply text with any prefix stripped.
  final String text;

  /// Raw payload byte count (prefix included) — truncation happens on the
  /// device BEFORE the prefix is stripped, so the bound is judged here, not
  /// on [text] (Gemini review, #881 finding 2).
  final int payloadLength;

  /// True when the payload sits at the device's truncation bound — the reply
  /// may have been cut and the UI should say so rather than present it as
  /// complete.
  bool get atReplyBound => payloadLength >= maxCliReplyPayload;
}

/// Parses a `[29][reply]` frame; null when [frame] is not a CLI reply.
/// Decoding is lenient (malformed bytes become U+FFFD) — a garbled reply is
/// still a reply, and dropping it would look like a timeout.
///
/// Prefix detection is positional (third character `|`), the same rule the
/// device and the repeater path use. A prefixless reply whose text happens to
/// carry `|` at index 2 mis-splits — inherent to the wire grammar, mitigated
/// by callers always sending a prefix so real replies reflect one.
CliReply? parseCliReply(Uint8List frame) {
  if (frame.isEmpty || frame[0] != respCodeCliReply) return null;
  final payloadLength = frame.length - 1;
  final raw = utf8.decode(frame.sublist(1), allowMalformed: true);
  if (raw.length >= 3 && raw[2] == '|') {
    return CliReply(
      prefix: raw.substring(0, 3),
      text: raw.substring(3),
      payloadLength: payloadLength,
    );
  }
  return CliReply(prefix: null, text: raw, payloadLength: payloadLength);
}
