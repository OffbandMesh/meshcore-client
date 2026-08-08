import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

// Buffer Reader - sequential binary data reader with pointer tracking
class BufferReader {
  int _pointer = 0;
  int _lastPointer = 0;
  final Uint8List _buffer;

  BufferReader(Uint8List data) : _buffer = Uint8List.fromList(data);

  int get remaining => _buffer.length - _pointer;

  int readByte() => readBytes(1)[0];

  Uint8List readBytes(int count) {
    _lastPointer = _pointer;
    if (_pointer + count > _buffer.length) {
      throw RangeError(
        'Attempted to read $count bytes at offset $_pointer, but only $remaining bytes remaining in buffer of length ${_buffer.length}',
      );
    }
    final data = _buffer.sublist(_pointer, _pointer + count);
    _pointer += count;
    return data;
  }

  void skipBytes(int count) {
    _lastPointer = _pointer;
    if (_pointer + count > _buffer.length) {
      throw RangeError(
        'Attempted to skip $count bytes at offset $_pointer, but only $remaining bytes remaining in buffer of length ${_buffer.length}',
      );
    }
    _pointer += count;
  }

  Uint8List readRemainingBytes() => readBytes(remaining);

  String readCStringGreedy(int maxLength) {
    _lastPointer = _pointer;
    final value = <int>[];
    final bytes = readBytes(maxLength);
    for (final byte in bytes) {
      if (byte == 0) break;
      value.add(byte);
    }
    try {
      return utf8.decode(Uint8List.fromList(value), allowMalformed: true);
    } catch (e) {
      return String.fromCharCodes(value); // Latin-1 fallback
    }
  }

  String readCString({int maxLength = -1}) {
    final backupPointer = _pointer;
    final value = <int>[];
    int counter = 0;
    final maxLen = maxLength >= 0 ? maxLength : remaining;
    while (counter < maxLen) {
      final byte = readByte();
      if (byte == 0) break;
      value.add(byte);
      counter++;
    }
    _lastPointer = backupPointer;
    try {
      return utf8.decode(Uint8List.fromList(value), allowMalformed: true);
    } catch (e) {
      return String.fromCharCodes(value); // Latin-1 fallback
    }
  }

  int readUInt8() => readBytes(1).buffer.asByteData().getUint8(0);
  int readInt8() => readBytes(1).buffer.asByteData().getInt8(0);
  int readUInt16LE() =>
      readBytes(2).buffer.asByteData().getUint16(0, Endian.little);
  int readUInt16BE() =>
      readBytes(2).buffer.asByteData().getUint16(0, Endian.big);
  int readUInt32LE() =>
      readBytes(4).buffer.asByteData().getUint32(0, Endian.little);
  int readUInt32BE() =>
      readBytes(4).buffer.asByteData().getUint32(0, Endian.big);
  int readInt16LE() =>
      readBytes(2).buffer.asByteData().getInt16(0, Endian.little);
  int readInt16BE() => readBytes(2).buffer.asByteData().getInt16(0, Endian.big);
  int readInt32LE() =>
      readBytes(4).buffer.asByteData().getInt32(0, Endian.little);

  int readInt24BE() {
    var value = (readByte() << 16) | (readByte() << 8) | readByte();
    if ((value & 0x800000) != 0) value -= 0x1000000;
    return value;
  }

  void resetPointer() => _pointer = 0;
  void rewind() => _pointer = _lastPointer;
}

// Buffer Writer - accumulating binary data builder
class BufferWriter {
  final BytesBuilder _builder = BytesBuilder();

  Uint8List toBytes() => _builder.toBytes();

  void writeByte(int byte) => _builder.addByte(byte);
  void writeBytes(Uint8List bytes) => _builder.add(bytes);

  void writeUInt16LE(int num) {
    final bytes = Uint8List(2)
      ..buffer.asByteData().setUint16(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeUInt32LE(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeInt32LE(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setInt32(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeString(String string) =>
      writeBytes(Uint8List.fromList(utf8.encode(string)));

  void writeCString(String string, int maxLength) {
    final bytes = Uint8List(maxLength);
    final encoded = utf8.encode(string);
    for (var i = 0; i < maxLength - 1 && i < encoded.length; i++) {
      bytes[i] = encoded[i];
    }
    writeBytes(bytes);
  }

  void writeHex(String hex) {
    writeBytes(hex2Uint8List(hex));
  }

  void writeBytesPadded(Uint8List bytes, int totalLength) {
    // Path data (64 bytes, zero-padded)
    final bytesPadded = Uint8List(totalLength);
    final len = bytes.length < totalLength ? bytes.length : totalLength;
    if (bytes.isNotEmpty && len > 0) {
      final copyLen = bytes.length < totalLength ? bytes.length : totalLength;
      for (int i = 0; i < copyLen; i++) {
        bytesPadded[i] = bytes[i];
      }
    }
    writeBytes(bytesPadded);
  }
}

Uint8List hex2Uint8List(String hex) {
  // Validate hex string length is even and not empty
  if (hex.isEmpty || hex.length % 2 != 0) {
    throw FormatException('Invalid hex string length: ${hex.length}');
  }
  List<int> result = [];
  for (int i = 0; i < hex.length ~/ 2; i++) {
    final hexByte = hex.substring(i * 2, i * 2 + 2);
    final byte = int.tryParse(hexByte, radix: 16);
    if (byte == null) {
      throw FormatException('Invalid hex characters at position $i: $hexByte');
    }
    result.add(byte);
  }
  return Uint8List.fromList(result);
}

// Command codes (to device)
const int cmdAppStart = 1;
const int cmdSendTxtMsg = 2;
const int cmdSendChannelTxtMsg = 3;
const int cmdGetContacts = 4;
const int cmdGetDeviceTime = 5;
const int cmdSetDeviceTime = 6;
const int cmdSendSelfAdvert = 7;
const int cmdSetAdvertName = 8;
const int cmdAddUpdateContact = 9;
const int cmdSyncNextMessage = 10;
const int cmdSetRadioParams = 11;
const int cmdSetRadioTxPower = 12;
const int cmdResetPath = 13;
const int cmdSetAdvertLatLon = 14;
const int cmdRemoveContact = 15;
const int cmdShareContact = 16;
const int cmdExportContact = 17;
const int cmdImportContact = 18;
const int cmdReboot = 19;
const int cmdGetBattAndStorage = 20;
const int cmdDeviceQuery = 22;
const int cmdSendLogin = 26;
const int cmdSendStatusReq = 27;
const int cmdGetContactByKey = 30;
const int cmdGetChannel = 31;
const int cmdSetChannel = 32;
const int cmdSendTracePath = 36;
const int cmdSetOtherParams = 38;
const int cmdSendTelemetryReq = 39;
const int cmdGetCustomVar = 40;
const int cmdSetCustomVar = 41;
const int cmdSendBinaryReq = 50;
const int cmdGetStats = 56;
const int cmdSendAnonReq = 57;
const int cmdSetAutoAddConfig = 58;
const int cmdGetAutoAddConfig = 59;
const int cmdSetPathHashMode = 61;

// Text message types
const int txtTypePlain = 0;
const int txtTypeCliData = 1;
const int txtTypeSigned = 2;

// Repeater request types (for server requests)
const int reqTypeGetStatus = 0x01;
const int reqTypeKeepAlive = 0x02;
const int reqTypeGetTelemetry = 0x03;
const int reqTypeGetAccessList = 0x05;
const int reqTypeGetNeighbors = 0x06;

Uint8List buildTelemetryBinaryPayload() {
  // Room servers/repeaters read byte 1 as an inverse telemetry permission mask.
  // Zero means "request every telemetry field allowed for this contact".
  return Uint8List.fromList([reqTypeGetTelemetry, 0x00, 0x00, 0x00, 0x00]);
}

// Repeater response codes
const int respServerLoginOk = 0;

// Response codes (from device)
const int respCodeOk = 0;
const int respCodeErr = 1;
const int respCodeContactsStart = 2;
const int respCodeContact = 3;
const int respCodeEndOfContacts = 4;
const int respCodeSelfInfo = 5;
const int respCodeSent = 6;
const int respCodeContactMsgRecv = 7;
const int respCodeChannelMsgRecv = 8;
const int respCodeCurrTime = 9;
const int respCodeNoMoreMessages = 10;
const int respCodeExportContact = 11;
const int respCodeBattAndStorage = 12;
const int respCodeDeviceInfo = 13;
const int respCodeContactMsgRecvV3 = 16;
const int respCodeChannelMsgRecvV3 = 17;
const int respCodeChannelInfo = 18;
const int respCodeCustomVars = 21;
const int respCodeAutoAddConfig = 25;
const int respCodeStats = 24;

/// Offband fork-only extension space (0xC0+), never collides with upstream,
/// never submitted upstream. Request and reply share the code. (#135)
const int cmdOffbandGps = 0xC1;
const int respCodeOffbandGps = 0xC1;

/// Request frame for [cmdOffbandGps], a bare 1-byte command, no payload. (#135)
Uint8List buildOffbandGpsRequestFrame() => Uint8List.fromList([cmdOffbandGps]);

// --- Offband FEM LNA command (0xC3), capability-gated. Heltec V4 external
// FEM LNA control; firmware counterpart OffbandMesh/meshcore-firmware#298.
//
// Deliberately a fork-private command rather than an extra byte on the stock
// CMD_SET_OTHER_PARAMS (38): that frame is shared with upstream MeshCore and is
// sent to every radio regardless of fork, so widening it would perturb stock
// firmware. Nothing here is emitted unless the capability bit is set. (#304)
const int cmdOffbandFemLna = 0xC3;
const int offbandFemLnaSet = 0x01;
const int offbandFemLnaGet = 0x02;

/// `0` = FEM LNA bypassed, `1` = enabled. Firmware default is enabled.
const int femLnaBypass = 0x00;
const int femLnaEnabled = 0x01;

/// Fixed delay a repeater applies before queueing a CLI reply for transmit.
///
/// Firmware `CLI_REPLY_DELAY_MILLIS` in `examples/simple_repeater/MyMesh.cpp`,
/// applied on both the direct and the flood reply path. It is unconditional, so
/// every CLI round trip pays it and any budget for one must include it.
const int cliReplyDelayMs = 600;

Uint8List buildOffbandFemLnaSetFrame(bool enabled) => Uint8List.fromList([
  cmdOffbandFemLna,
  offbandFemLnaSet,
  enabled ? femLnaEnabled : femLnaBypass,
]);

Uint8List buildOffbandFemLnaGetFrame() =>
    Uint8List.fromList([cmdOffbandFemLna, offbandFemLnaGet]);

/// Reply to a `0xC3` request: `[0xC3][sub][value]`.
///
/// The value is the **post-apply hardware state, not an echo of the request**
/// (firmware #298 as-built): if the FEM ever refused a write, this reports the
/// truth rather than confirming a change that didn't take. Always render from
/// this value; never assume the written value stuck.
///
/// Error replies are never 0xC3-prefixed, so they don't reach this parser:
/// malformed → `[respCodeErr][errCodeIllegalArg]`; a request to a non-capable
/// board → `[respCodeErr][errCodeUnsupportedCmd]` (unreachable when gated on
/// the capability bit, but firmware answers it defensively).
class OffbandFemLnaReply {
  const OffbandFemLnaReply(this.subType, this.value);
  final int subType;
  final int value;

  bool get enabled => value != femLnaBypass;
}

OffbandFemLnaReply? parseOffbandFemLnaReply(Uint8List frame) {
  if (frame.length < 3 || frame[0] != cmdOffbandFemLna) return null;
  return OffbandFemLnaReply(frame[1], frame[2]);
}

// --- Offband caplog serial-capture download (0xC4), companion-API only; NEVER
// on the mesh. Firmware counterpart OffbandMesh/meshcore-firmware#406.
//
// 0xC4, NOT 0xC3: the firmware first merged this on 0xC3, which collides with
// cmdOffbandFemLna (0xC3, #298), the caplog handler swallowed every 0xC3 frame
// before FEM/LNA dispatch. Reassigned to 0xC4, the next free code in the 0xC0+
// space (0xC0 config, 0xC1 GPS, 0xC2 block, 0xC3 FEM LNA).
//
// Request: bare [0xC4], no payload (mirrors cmdOffbandGps). Reply is a streamed
// dump: START [0xC4, 0x01, total_len(uint32 LE)] → CHUNK [0xC4, 0x02, <bytes>]*
// → END [0xC4, 0x03]. The firmware auto-stops capture for the duration (so
// offsets stay stable) and rejects with the generic [respCodeErr] when another
// stream (block-list / contacts / observer config) is already in flight. (#430)
const int cmdOffbandCaplog = 0xC4;
const int respCodeOffbandCaplog = 0xC4;
const int caplogSubStart = 0x01;
const int caplogSubChunk = 0x02;
const int caplogSubEnd = 0x03;

// Caplog request sub-codes in cmd_frame[1]. A bare [0xC4] (len 1) is DOWNLOAD
// for back-compat. Firmware #417/#408. (#430)
const int caplogReqDownload = 0x01;
const int caplogReqEnable = 0x02; // [0xC4,0x02,(level)], omit level for default
const int caplogReqDisable = 0x03;
const int caplogReqErase = 0x04;
const int caplogReqStatus = 0x05;

// Caplog CONTROL response sub-codes in out_frame[1] (download stream sub-codes
// caplogSubStart/Chunk/End are above).
const int caplogRespAck = 0x10; // [0xC4,0x10, req_op, ok(0|1)]
const int caplogRespStatus =
    0x11; // [0xC4,0x11, enabled, level, used(4B LE), cap(4B LE)]

/// Request frame to download the device's serial-capture buffer, a bare 1-byte
/// command, no payload (firmware treats bare [0xC4] as DOWNLOAD). (#430)
Uint8List buildOffbandCaplogRequestFrame() =>
    Uint8List.fromList([cmdOffbandCaplog]);

/// Enable capture on the device (default verbosity level). (#430)
Uint8List buildOffbandCaplogEnableFrame() =>
    Uint8List.fromList([cmdOffbandCaplog, caplogReqEnable]);

/// Disable (stop) capture on the device. (#430)
Uint8List buildOffbandCaplogDisableFrame() =>
    Uint8List.fromList([cmdOffbandCaplog, caplogReqDisable]);

/// Erase the device's capture buffer. (#430)
Uint8List buildOffbandCaplogEraseFrame() =>
    Uint8List.fromList([cmdOffbandCaplog, caplogReqErase]);

/// Query capture status (enabled / level / used / capacity). (#430)
Uint8List buildOffbandCaplogStatusFrame() =>
    Uint8List.fromList([cmdOffbandCaplog, caplogReqStatus]);

/// Parsed `[0xC4,0x10, req_op, ok]` control acknowledgement. [reqOp] echoes the
/// request sub-code (enable/disable/erase); [ok] is the device's result. (#430)
class CaplogAck {
  const CaplogAck(this.reqOp, {required this.ok});
  final int reqOp;
  final bool ok;
}

/// Parse a caplog control ACK; null if [frame] isn't one. (#430)
CaplogAck? parseCaplogAck(Uint8List frame) {
  if (frame.length < 4 ||
      frame[0] != respCodeOffbandCaplog ||
      frame[1] != caplogRespAck) {
    return null;
  }
  return CaplogAck(frame[2], ok: frame[3] == 1);
}

/// Parsed `[0xC4,0x11, enabled, level, used(4B LE), cap(4B LE)]` status. (#430)
class CaplogDeviceStatus {
  const CaplogDeviceStatus({
    required this.enabled,
    required this.level,
    required this.usedBytes,
    required this.capacityBytes,
  });
  final bool enabled;
  final int level;
  final int usedBytes;
  final int capacityBytes;
}

/// Parse a caplog STATUS reply; null if [frame] isn't one. (#430)
CaplogDeviceStatus? parseCaplogStatus(Uint8List frame) {
  if (frame.length < 12 ||
      frame[0] != respCodeOffbandCaplog ||
      frame[1] != caplogRespStatus) {
    return null;
  }
  return CaplogDeviceStatus(
    enabled: frame[2] != 0,
    level: frame[3],
    usedBytes: readUint32LE(frame, 4),
    capacityBytes: readUint32LE(frame, 8),
  );
}

// --- Offband block command (0xC2), capability-gated; see
// docs/architecture/block-contract-as-built.md §8. Firmware as-built PR #247. ---
const int cmdOffbandBlock = 0xC2;
const int offbandBlockAdd = 0x01;
const int offbandBlockRemove = 0x02;
const int offbandBlockList = 0x03;
const int offbandBlockClear = 0x04;

/// Result of a malformed 0xC2 request: firmware replies with the GENERIC error
/// frame `[respCodeErr(1)][errCodeIllegalArg(6)]`, NOT 0xC2-prefixed, so the
/// app must recognise the 2-byte error frame and not wait for a 0xC2 echo.
const int errCodeIllegalArg = 6;

/// `ERR_CODE_UNSUPPORTED_CMD`, returned for an Offband command the connected
/// board can't service (e.g. a `0xC3` FEM LNA request to a board without FEM
/// control). Unreachable when the capability bit is respected; firmware answers
/// it defensively against a stale or mis-gated client. (#304)
const int errCodeUnsupportedCmd = 1;

Uint8List buildOffbandBlockAddFrame(Uint8List pubKey) =>
    Uint8List.fromList([cmdOffbandBlock, offbandBlockAdd, ...pubKey]);
Uint8List buildOffbandBlockRemoveFrame(Uint8List pubKey) =>
    Uint8List.fromList([cmdOffbandBlock, offbandBlockRemove, ...pubKey]);
Uint8List buildOffbandBlockListFrame() =>
    Uint8List.fromList([cmdOffbandBlock, offbandBlockList]);
Uint8List buildOffbandBlockClearFrame() =>
    Uint8List.fromList([cmdOffbandBlock, offbandBlockClear]);

/// Parsed reply to ADD/REMOVE/CLEAR: the sub-type and the result byte `ok`.
/// ADD: ok=1 present-after-call / ok=0 store-full. REMOVE: ok=1 removed /
/// ok=0 not-present. (LIST is a streamed dump, parsed separately.)
class OffbandBlockReply {
  final int sub;
  final int ok;
  const OffbandBlockReply(this.sub, this.ok);
  bool get success => ok == 1;
}

/// Parse a 3-byte `[0xC2][sub][ok]` reply; null if not an Offband-block reply.
OffbandBlockReply? parseOffbandBlockReply(Uint8List frame) {
  if (frame.length < 3 || frame[0] != cmdOffbandBlock) return null;
  return OffbandBlockReply(frame[1], frame[2]);
}

/// True iff the connected firmware understands the `0xC1` GPS extension. Gated
/// on the `offband_caps` byte being present: that byte is an Offband-fork
/// addition (device-info v14+) which stock/upstream MeshCore never emits, so a
/// null caps value means non-Offband firmware that couldn't answer `0xC1`, and
/// must not be pinged with it. (#144)
///
/// Interim presence-gate: a dedicated `OFFBAND_CAP_GPS` bit (firmware
/// follow-up) would let an Offband build without GPS opt out; until firmware
/// defines one, any Offband v14+ radio is assumed to speak `0xC1`.
bool firmwareSupportsOffbandGps(int? offbandCaps) => offbandCaps != null;

/// `OFFBAND_CAP_BLOCK` bit (bit 1) in the `offband_caps` byte of the device-info
/// reply: an Offband radio that persists a block list and drops blocked DMs at
/// receive (firmware PR #247, `FIRMWARE_VER_CODE 15`). Unlike the loose GPS
/// presence-gate above, block requires the **explicit bit** set AND
/// `FIRMWARE_VER_CODE >= 15`; absent → app-only mode (no sync, no firmware drop).
const int offbandCapBlock = 0x02;

/// `OFFBAND_CAP_FEM_LNA` bit (bit 2) in the `offband_caps` byte: this radio can
/// control its external FEM LNA (firmware #298).
///
/// PROVISIONAL, firmware owns the caps byte and has not yet confirmed 0x04 as
/// free. Do not ship against this without that confirmation (#304).
///
/// Gate on the BIT ONLY, never on model or version: firmware derives it at
/// runtime from the auto-detected FEM chip (KCT8103L vs GC1109), so it is a
/// per-unit answer, two Heltec V4s can legitimately disagree, and other
/// FEM-bearing boards report false today.
const int offbandCapFemLna = 0x04;

bool firmwareSupportsOffbandFemLna(int? offbandCaps) =>
    offbandCaps != null && (offbandCaps & offbandCapFemLna) != 0;

bool firmwareSupportsOffbandBlock(int? offbandCaps, int? firmwareVerCode) =>
    offbandCaps != null &&
    (offbandCaps & offbandCapBlock) != 0 &&
    (firmwareVerCode ?? 0) >= 15;

/// Caplog serial-capture capability (firmware #427). The bit is compile-time
/// static in device-info, so it's reliable across reboots, the client re-reads
/// it on reconnect and never has to race a STATUS probe. Bit 5 (0x08/0x10 are
/// reserved for WiFi-companion #365 / display-config); requires FIRMWARE_VER_CODE
/// >= 17, the version that introduced it.
const int offbandCapCaplog = 0x20;

/// `offband_caps` BYTE 2 bits (device-info frame offset 84, firmware #508).
///
/// Bit assignment CONFIRMED by firmware (FuchsiaCreek, 2026-08-01): bit 0 is
/// the notification scope, bit 1 is the button matrix. This is the reverse of
/// the order the two epics were filed in, so do not infer it from issue
/// numbers.
///
/// `offbandCap2NotifyScope` is set **only where `PIN_BUZZER` is defined**, the
/// same principle as FEM LNA gating on `canControlLoRaFemLna()`. Heltec V4 and
/// RAK4631 have no buzzer and will never advertise it. Gate on the BIT ONLY,
/// never on model or version code: it is a per-unit answer.
///
/// Bit 1 is still unclaimed pending the #509 firmware PR.
const int offbandCap2NotifyScope = 0x01;
const int offbandCap2ButtonMatrix = 0x02;

/// True iff this radio advertises a configurable button-action matrix (#474).
/// False whenever byte 2 is absent, which is every radio predating #508 and is
/// never an error.
bool firmwareSupportsButtonMatrix(int? offbandCaps2) =>
    offbandCaps2 != null && (offbandCaps2 & offbandCap2ButtonMatrix) != 0;

/// True iff this radio advertises a settable device notification scope (#475).
bool firmwareSupportsNotifyScope(int? offbandCaps2) =>
    offbandCaps2 != null && (offbandCaps2 & offbandCap2NotifyScope) != 0;

bool firmwareSupportsOffbandCaplog(int? offbandCaps, int? firmwareVerCode) =>
    offbandCaps != null &&
    (offbandCaps & offbandCapCaplog) != 0 &&
    (firmwareVerCode ?? 0) >= 17;

/// Packet-hash query capability (firmware #611, cap byte 2 bit 3). Lets the
/// client ask firmware for the authoritative on-air hash of a channel message
/// it sent, keyed by (msg_timestamp, channel_idx), to correlate against
/// CoreScope observer counts (#524). Allocation provisional until the firmware
/// PR merges; confirm against it before release.
const int offbandCap2PktHash = 0x08;

/// True iff this radio supports the 0xC6 packet-hash query. Requires both the
/// cap-byte-2 bit AND FIRMWARE_VER_CODE >= 22. The client must never emit 0xC6
/// unless this is true.
bool firmwareSupportsPktHash(int? offbandCaps2, int? firmwareVerCode) =>
    offbandCaps2 != null &&
    (offbandCaps2 & offbandCap2PktHash) != 0 &&
    (firmwareVerCode ?? 0) >= 22;

/// 0xC6 CMD_OFFBAND_PKT_HASH (firmware #611). Client-issued query, never a push;
/// the stock channel-send OK reply is untouched.
const int cmdOffbandPktHash = 0xC6;
const int pktHashReqGet = 0x01;
const int pktHashRespGet = 0x01;
const int pktHashRespErr = 0x7F;

/// Build a 0xC6 GET request for the hash of a sent channel message, keyed by
/// the (msg_timestamp, channel_idx) the client used in CMD_SEND_CHANNEL_TXT_MSG.
/// Wire: [0xC6][0x01][ts:4 LE][chan:1] = 7 bytes.
Uint8List buildOffbandPktHashGetFrame(int msgTimestamp, int channelIdx) {
  final frame = Uint8List(7);
  frame[0] = cmdOffbandPktHash;
  frame[1] = pktHashReqGet;
  ByteData.sublistView(frame, 2, 6).setUint32(0, msgTimestamp, Endian.little);
  frame[6] = channelIdx & 0xFF;
  return frame;
}

/// A parsed 0xC6 success reply: the on-air packet hash plus the echoed key,
/// so a reply can be matched to its request without relying on ordering.
class OffbandPktHash {
  const OffbandPktHash({
    required this.timestamp,
    required this.channelIdx,
    required this.hashHex,
  });

  /// msg_timestamp echoed from the request.
  final int timestamp;

  /// channel_idx echoed from the request.
  final int channelIdx;

  /// 16 lowercase hex chars, matching CoreScope's hash and the client's own
  /// [_computePacketHash] format.
  final String hashHex;
}

/// Parse a 0xC6 reply. Returns the hash on a success reply
/// ([0xC6][0x01][ts:4][chan:1][hash:8], 15 bytes), or null on the error reply
/// ([0xC6][0x7F][reason]) or any malformed frame.
OffbandPktHash? parseOffbandPktHashReply(Uint8List frame) {
  if (frame.length < 15) return null;
  if (frame[0] != cmdOffbandPktHash || frame[1] != pktHashRespGet) return null;
  final ts = ByteData.sublistView(frame, 2, 6).getUint32(0, Endian.little);
  final chan = frame[6];
  final hashHex = frame
      .sublist(7, 15)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return OffbandPktHash(timestamp: ts, channelIdx: chan, hashHex: hashHex);
}

const int statsTypeCore = 0;
const int statsTypeRadio = 1;
const int statsTypePackets = 2;

// Push codes (async from device)
const int pushCodeAdvert = 0x80;
const int pushCodePathUpdated = 0x81;
const int pushCodeSendConfirmed = 0x82;
const int pushCodeMsgWaiting = 0x83;
const int pushCodeLoginSuccess = 0x85;
const int pushCodeLoginFail = 0x86;
const int pushCodeStatusResponse = 0x87;
const int pushCodeLogRxData = 0x88;
const int pushCodeTraceData = 0x89;
const int pushCodeNewAdvert = 0x8A;
const int pushCodeTelemetryResponse = 0x8B;
const int pushCodeBinaryResponse = 0x8C;
const int pushCodeChannelsChanged =
    0x91; // #429 part A: device channel table changed; re-poll getChannels

// Contact/advertisement types
const int advTypeChat = 1;
const int advTypeRepeater = 2;
const int advTypeRoom = 3;
const int advTypeSensor = 4;

const int teleModeDeny = 0;
const int teleModeAllowFlags = 1; // use contact.flags
const int teleModeAllowAll = 2;

// Payload Types
const int payloadTypeREQ =
    0x00; // request (prefixed with dest/src hashes, MAC) (enc data: timestamp, blob)
const int payloadTypeRESPONSE =
    0x01; // response to REQ or ANON_REQ (prefixed with dest/src hashes, MAC) (enc data: timestamp, blob)
const int payloadTypeTXTMSG =
    0x02; // a plain text message (prefixed with dest/src hashes, MAC) (enc data: timestamp, text)
const int payloadTypeACK = 0x03; // a simple ack
const int payloadTypeADVERT = 0x04; // a node advertising its Identity
const int payloadTypeGRPTXT =
    0x05; // an (unverified) group text message (prefixed with channel hash, MAC) (enc data: timestamp, "name: msg")
const int payloadTypeGRPDATA =
    0x06; // an (unverified) group datagram (prefixed with channel hash, MAC) (enc data: timestamp, blob)
const int payloadTypeANONREQ =
    0x07; // generic request (prefixed with dest_hash, ephemeral pub_key, MAC) (enc data: ...)
const int payloadTypePATH =
    0x08; // returned path (prefixed with dest/src hashes, MAC) (enc data: path, extra)
const int payloadTypeTRACE = 0x09; // trace a path, collecting SNI for each hop
const int payloadTypeMULTIPART = 0x0A; // packet is one of a set of packets
const int payloadTypeCONTROL = 0x0B; // a control/discovery packet
//...
const int payloadTypeRawCustom =
    0x0F; // custom packet as raw bytes, for applications with custom encryption, payloads, etc

//auto-add flags
const int autoAddOverwriteOldestFlag =
    1 << 0; // 0x01 - overwrite oldest non-favourite when full
const int autoAddChatFlag =
    1 << 1; // 0x02 - auto-add Chat (Companion) (ADV_TYPE_CHAT)
const int autoAddRepeaterFlag =
    1 << 2; // 0x04 - auto-add Repeater (ADV_TYPE_REPEATER)
const int autoAddRoomServerFlag =
    1 << 3; // 0x08 - auto-add Room Server (ADV_TYPE_ROOM)
const int autoAddSensorFlag =
    1 << 4; // 0x10 - auto-add Sensor (ADV_TYPE_SENSOR)

// Sizes
const int pubKeySize = 32;
const int signatureSize = 64;
const int maxPathSize = 64;
const int pathHashSize = 1;
const int maxNameSize = 32;
const int maxFrameSize = 172;
const int appProtocolVersion = 4;
// Matches firmware MAX_TEXT_LEN (10 * CIPHER_BLOCK_SIZE).
const int maxTextPayloadBytes = 160;
const int _sendTextMsgOverheadBytes =
    1 + 1 + 1 + 4 + 6 + 1 + 2; // +2 safety margin
const int _sendChannelTextMsgOverheadBytes =
    1 + 1 + 1 + 4 + 1 + 2; // +2 safety margin

// [maxFrameBytes] is the largest frame the active transport can write in one
// operation. On BLE that is ATT_MTU - 3, which can be smaller than [maxFrameSize];
// pass it so a max-length message never overflows the characteristic write (#395).
// Defaults to [maxFrameSize] for callers without a live transport (USB/TCP, tests).
int maxContactMessageBytes({int? maxFrameBytes}) {
  final frameBudget = maxFrameBytes ?? maxFrameSize;
  final byFrame = frameBudget - _sendTextMsgOverheadBytes;
  return _minPositive(byFrame, maxTextPayloadBytes);
}

int maxChannelMessageBytes(String? senderName, {int? maxFrameBytes}) {
  final frameBudget = maxFrameBytes ?? maxFrameSize;
  final nameLength = _senderNameBytes(senderName);
  final prefixBytes = nameLength + 2; // "<name>: "
  final byPayload = maxTextPayloadBytes - prefixBytes;
  // The wire text is "<name>: <userText>", so the prefix eats into the frame
  // budget too. At maxFrameSize the payload limit always governed and this went
  // unnoticed; with a smaller BLE budget the frame limit can govern, so the
  // prefix must be subtracted here or a channel frame can still overflow (#395).
  final byFrame = frameBudget - _sendChannelTextMsgOverheadBytes - prefixBytes;
  return _minPositive(byPayload, byFrame);
}

int _senderNameBytes(String? senderName) {
  if (senderName == null || senderName.isEmpty) return maxNameSize - 1;
  final bytes = utf8.encode(senderName);
  final maxBytes = maxNameSize - 1;
  return bytes.length > maxBytes ? maxBytes : bytes.length;
}

int _minPositive(int a, int b) {
  final minValue = a < b ? a : b;
  return minValue < 0 ? 0 : minValue;
}

// Contact frame offsets
const int contactPubKeyOffset = 1;
const int contactTypeOffset = 33;
const int contactFlagsOffset = 34;
const int contactFlagFavorite = 0x01;
const int contactFlagTeleBase = 0x02; // 'base' permission includes battery
const int contactFlagTeleLoc = 0x04;
const int contactFlagTeleEnv = 0x08; //access environment sensors
const int contactPathLenOffset = 35;
const int contactPathOffset = 36;
const int contactNameOffset = 100;
const int contactTimestampOffset = 132;
const int contactLatOffset = 136;
const int contactLonOffset = 140;
const int contactLastModOffset = 144;
const int contactFrameSize = 148;

// Message frame offsets
const int msgPubKeyOffset = 1;
const int msgTimestampOffset = 33;
const int msgFlagsOffset = 37;
const int msgTextOffset = 38;

class ParsedContactText {
  final Uint8List senderPrefix;
  final String text;
  const ParsedContactText({required this.senderPrefix, required this.text});
}

ParsedContactText? parseContactMessageText(Uint8List frame) {
  if (frame.isEmpty) return null;

  final message = BufferReader(frame);
  try {
    final code = message.readByte();
    if (code != respCodeContactMsgRecv && code != respCodeContactMsgRecvV3) {
      return null;
    }

    // Companion radio layout:
    // [code][snr?][res?][res?][prefix x6][path_len][txt_type][timestamp x4][extra?][text...]
    if (code == respCodeContactMsgRecvV3) {
      // Skip SNR and reserved bytes in v3 layout
      message.skipBytes(3);
    }
    final senderPrefix = message.readBytes(6); // public key
    message.skipBytes(1); // path length
    final textType = message.readByte();
    message.skipBytes(4); // timestamp (4 bytes)

    final shiftedType = textType >> 2;
    final isSigned = shiftedType == txtTypeSigned || textType == txtTypeSigned;
    if (isSigned) {
      // Signed messages have a 4-byte signature after the timestamp, before the text
      message.skipBytes(4);
    }
    final text = message.readCString();
    if (text.isEmpty) return null;

    return ParsedContactText(senderPrefix: senderPrefix, text: text);
  } catch (e) {
    debugPrint('Error parsing contact message text: $e');
    return null;
  }
}

// Helper to read uint32 little-endian
int readUint32LE(Uint8List data, int offset) {
  return data[offset] |
      (data[offset + 1] << 8) |
      (data[offset + 2] << 16) |
      (data[offset + 3] << 24);
}

// Helper to read uint16 little-endian
int readUint16LE(Uint8List data, int offset) {
  return data[offset] | (data[offset + 1] << 8);
}

// Helper to read int32 little-endian
int readInt32LE(Uint8List data, int offset) {
  int val = readUint32LE(data, offset);
  if (val >= 0x80000000) val -= 0x100000000;
  return val;
}

// Path-length byte from the firmware. This is a PACKED field, and both halves
// are authoritative, the path is self-describing on the wire:
//
//   high 2 bits = hash size - 1  (0..2 -> 1..3 bytes per hop hash)
//   low  6 bits = hash COUNT     (the number of HOPS, 0-63)
//   byte length = count * size
//
// Verified against firmware `src/Packet.h:79-84`:
//   getPathHashSize()  == (path_len >> 6) + 1
//   getPathHashCount() == path_len & 63
//   getPathByteLen()   == getPathHashCount() * getPathHashSize()
//   setPathHashSizeAndCount(sz, n) { path_len = ((sz - 1) << 6) | (n & 63); }
//
// The high bits are set deliberately by that setter, so the per-path width
// travels with the path. The companion contact frame carries this same encoded
// byte verbatim: `Packet::copyPath()` returns path_len unchanged
// (`src/Packet.cpp:32-35`) into `ContactInfo.out_path_len`
// (`src/helpers/BaseChatMesh.cpp:319`), which `writeContactRespFrame` emits
// as-is (`examples/companion_radio/MyMesh.cpp:205-212`).
//
// A prior comment here claimed the low 6 bits were a BYTE count and that the
// high bits were "not reliably populated". Both were wrong, and #222 plus the
// Contact decode were built on them: the app read `count` bytes where firmware
// meant `count` hops, keeping half of every path at 2-byte width. (#309)
//
// TX counterparts: buildSetPathHashModeFrame (CMD_SET_PATH_HASH_MODE) sets the
// device-wide default width; encodePathLen() packs a per-path value to send.
int pathHopCount(int pathLenRaw) => pathLenRaw & 0x3F;
int pathHashSizeBytes(int pathLenRaw) => ((pathLenRaw >> 6) & 0x03) + 1;

/// Byte length of the hop-hash array described by a raw path-length byte.
int pathByteLength(int pathLenRaw) =>
    pathHopCount(pathLenRaw) * pathHashSizeBytes(pathLenRaw);

/// Packs a hop count and per-hop hash width into the firmware path-length byte.
///
/// Mirrors firmware `Packet::setPathHashSizeAndCount`. Sending a bare hop count
/// (mode bits 00) tells the radio "1-byte hashes", so a 2-byte path routed that
/// way is read one byte per hop and goes to nodes that were never on the route.
/// Width is clamped to 1..3; mode 3 is reserved by firmware
/// (`isValidPathLen` rejects hash_size == 4). (#309)
int encodePathLen(int hopCount, int hashWidth) {
  final w = hashWidth.clamp(1, 3);
  return ((w - 1) << 6) | (hopCount & 0x3F);
}

/// Readable strings from a RESP_CODE_DEVICE_INFO frame: build date, model, and
/// firmware version, NUL-terminated after the 8-byte header and before the
/// binary config block (client_repeat/path-hash/caps live at bytes 80-82).
/// Collects printable-ASCII runs (>=2 chars) from byte 8 up to byte 80. (#134)
List<String> parseDeviceInfoStrings(Uint8List frame) {
  final out = <String>[];
  final buf = StringBuffer();
  final end = frame.length < 80 ? frame.length : 80;
  for (var i = 8; i < end; i++) {
    final b = frame[i];
    if (b >= 0x20 && b < 0x7f) {
      buf.writeCharCode(b);
    } else {
      if (buf.length >= 2) out.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.length >= 2) out.add(buf.toString());
  return out;
}

/// Maps a [parseDeviceInfoStrings] list to (version, model, build date),
/// anchored from the END: the firmware version is the last string and the most
/// likely to be present, model second-to-last, build date third-to-last. A
/// partial set keeps the version correct instead of shifting every field. (#134)
({String? version, String? model, String? buildDate}) deviceInfoFields(
  List<String> strings,
) {
  final n = strings.length;
  return (
    version: n >= 1 ? strings[n - 1] : null,
    model: n >= 2 ? strings[n - 2] : null,
    buildDate: n >= 3 ? strings[n - 3] : null,
  );
}

// Helper to convert uint32 to hex string
String ackHashToHex(int ackHash) {
  return ackHash.toRadixString(16).padLeft(8, '0');
}

// Helper to convert public key to hex string
String pubKeyToHex(Uint8List pubKey) {
  return pubKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// Helper to convert hex string to public key
Uint8List hexToPubKey(String hex) {
  final result = Uint8List(pubKeySize);
  for (int i = 0; i < pubKeySize && i * 2 + 1 < hex.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

// Build CMD_GET_CONTACTS frame
Uint8List buildGetContactsFrame({int? since}) {
  final writer = BufferWriter();
  writer.writeByte(cmdGetContacts);
  if (since != null) {
    writer.writeUInt32LE(since);
  }
  return writer.toBytes();
}

// Build CMD_SEND_LOGIN frame
// Format: [cmd][pub_key x32][password...]\0
Uint8List buildSendLoginFrame(Uint8List recipientPubKey, String password) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendLogin);
  writer.writeBytes(recipientPubKey);
  writer.writeString(password);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build CMD_SEND_STATUS_REQ frame
// Format: [cmd][pub_key x32]
Uint8List buildSendStatusRequestFrame(Uint8List recipientPubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendStatusReq);
  writer.writeBytes(recipientPubKey);
  return writer.toBytes();
}

// Build CMD_SEND_TXT_MSG frame (companion_radio format)
// Format: [cmd][txt_type][attempt][timestamp x4][pub_key_prefix x6][text...]\0
Uint8List buildSendTextMsgFrame(
  Uint8List recipientPubKey,
  String text, {
  int attempt = 0,
  int? timestampSeconds,
}) {
  final timestamp =
      timestampSeconds ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final writer = BufferWriter();
  writer.writeByte(cmdSendTxtMsg);
  writer.writeByte(txtTypePlain);
  writer.writeByte(attempt.clamp(0, 255));
  writer.writeUInt32LE(timestamp);
  writer.writeBytes(recipientPubKey.sublist(0, 6));
  writer.writeString(text);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build CMD_SEND_CHANNEL_TXT_MSG frame
// Format: [cmd][txt_type][channel_idx][timestamp x4][text...]
// [timestamp] (seconds) may be supplied by the caller so it can correlate the
// send to the firmware packet hash (0xC6, #524); defaults to now.
Uint8List buildSendChannelTextMsgFrame(
  int channelIndex,
  String text, {
  int? timestamp,
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final writer = BufferWriter();
  writer.writeByte(cmdSendChannelTxtMsg);
  writer.writeByte(txtTypePlain);
  writer.writeByte(channelIndex);
  writer.writeUInt32LE(ts);
  writer.writeString(text);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build CMD_REMOVE_CONTACT frame
Uint8List buildRemoveContactFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdRemoveContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

/// Byte length of the client id carried in [buildAppStartFrame] (#297).
///
/// 6 is load-bearing, not arbitrary: stock firmware treats `cmd_frame[1..7]` as
/// reserved and reads the app name at a FIXED offset 8, while Wadamesh reads
/// byte 1 as the client-id length and the app name at `2 + cid_len`. Only
/// `cid_len == 6` puts the name at 8 for both, so one frame serves both.
const int clientIdLength = 6;

// Build CMD_APP_START frame
// Format: [cmd][cid_len=6][client_id x6][app_name...]
// Stock reads bytes 1..7 as reserved + name at 8; Wadamesh reads the client id
// and lands on the same name offset. See [clientIdLength].
Uint8List buildAppStartFrame({
  String appName = 'MeshCoreOpen',
  Uint8List? clientId,
}) {
  final id = Uint8List(clientIdLength);
  if (clientId != null) {
    // Truncate or zero-pad: the length byte must stay 6 or the app-name offset
    // desyncs on one of the two firmwares.
    id.setRange(0, min(clientId.length, clientIdLength), clientId);
  }
  final writer = BufferWriter();
  writer.writeByte(cmdAppStart);
  writer.writeByte(clientIdLength);
  writer.writeBytes(id);
  writer.writeString(appName);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build CMD_DEVICE_QUERY frame
Uint8List buildDeviceQueryFrame({int appVersion = appProtocolVersion}) {
  return Uint8List.fromList([cmdDeviceQuery, appVersion]);
}

// Build CMD_GET_DEVICE_TIME frame
Uint8List buildGetDeviceTimeFrame() {
  return Uint8List.fromList([cmdGetDeviceTime]);
}

// Build CMD_GET_BATT_AND_STORAGE frame
Uint8List buildGetBattAndStorageFrame() {
  return Uint8List.fromList([cmdGetBattAndStorage]);
}

/// Companion radio stats: [56][statsType] where statsType is statsTypeCore/Radio/Packets.
Uint8List buildGetStatsFrame(int statsType) {
  return Uint8List.fromList([cmdGetStats, statsType & 0xFF]);
}

/// Path hash width on air: [61][0][mode], mode 0..2 → (mode+1) bytes per hop hash.
Uint8List buildSetPathHashModeFrame(int mode) {
  final m = mode.clamp(0, 2);
  return Uint8List.fromList([cmdSetPathHashMode, 0, m]);
}

// Build CMD_SET_DEVICE_TIME frame
Uint8List buildSetDeviceTimeFrame(int timestamp) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetDeviceTime);
  writer.writeUInt32LE(timestamp);
  return writer.toBytes();
}

// Build CMD_SEND_SELF_ADVERT frame
// Format: [cmd][flood_flag]
Uint8List buildSendSelfAdvertFrame({bool flood = false}) {
  return Uint8List.fromList([cmdSendSelfAdvert, flood ? 1 : 0]);
}

// Build CMD_SET_ADVERT_NAME frame
// Format: [cmd][name...]
Uint8List buildSetAdvertNameFrame(String name) {
  final nameBytes = utf8.encode(name);
  final nameLen = nameBytes.length < maxNameSize
      ? nameBytes.length
      : maxNameSize - 1;
  final writer = BufferWriter();
  writer.writeByte(cmdSetAdvertName);
  writer.writeBytes(Uint8List.fromList(nameBytes.sublist(0, nameLen)));
  return writer.toBytes();
}

// Build CMD_SET_ADVERT_LATLON frame
// Format: [cmd][lat x4][lon x4]
Uint8List buildSetAdvertLatLonFrame(double lat, double lon) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetAdvertLatLon);
  writer.writeInt32LE((lat * 1000000).round());
  writer.writeInt32LE((lon * 1000000).round());
  return writer.toBytes();
}

Uint8List buildSetCustomVarFrame(String value) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetCustomVar);
  writer.writeString(value);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build CMD_REBOOT frame
// Format: [cmd]["reboot"]
Uint8List buildRebootFrame() {
  return Uint8List.fromList([cmdReboot, ...utf8.encode('reboot')]);
}

// Build CMD_SYNC_NEXT_MESSAGE frame
Uint8List buildSyncNextMessageFrame() {
  return Uint8List.fromList([cmdSyncNextMessage]);
}

// Build CMD_GET_CHANNEL frame
Uint8List buildGetChannelFrame(int channelIndex) {
  return Uint8List.fromList([cmdGetChannel, channelIndex]);
}

// Build CMD_SET_CHANNEL frame
// Format: [cmd][idx][name x32][psk x16]
Uint8List buildSetChannelFrame(int channelIndex, String name, Uint8List psk) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetChannel);
  writer.writeByte(channelIndex);
  writer.writeCString(name, 32);
  // Write PSK (16 bytes, zero-padded)
  final pskPadded = Uint8List(16);
  for (int i = 0; i < 16 && i < psk.length; i++) {
    pskPadded[i] = psk[i];
  }
  writer.writeBytes(pskPadded);
  return writer.toBytes();
}

// Build CMD_SET_RADIO_PARAMS frame
// Format: [cmd][freq x4][bw x4][sf][cr] (pre-v9)
//         [cmd][freq x4][bw x4][sf][cr][repeat] (firmware v9+)
// freq: frequency in Hz (300000-2500000)
// bw: bandwidth in Hz (7000-500000)
// sf: spreading factor (5-12)
// cr: coding rate (5-8)
// clientRepeat: enable off-grid packet repeat (firmware v9+, omit for older)
Uint8List buildSetRadioParamsFrame(
  int freqHz,
  int bwHz,
  int sf,
  int cr, {
  bool? clientRepeat,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetRadioParams);
  writer.writeUInt32LE(freqHz);
  writer.writeUInt32LE(bwHz);
  writer.writeByte(sf);
  writer.writeByte(cr);
  if (clientRepeat != null) {
    writer.writeByte(clientRepeat ? 1 : 0);
  }
  return writer.toBytes();
}

// Build CMD_SET_RADIO_TX_POWER frame
// Format: [cmd][power_dbm]
Uint8List buildSetRadioTxPowerFrame(int powerDbm) {
  return Uint8List.fromList([cmdSetRadioTxPower, powerDbm]);
}

// Build CMD_RESET_PATH frame
// Format: [cmd][pub_key x32]
Uint8List buildResetPathFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdResetPath);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

// Build CMD_ADD_UPDATE_CONTACT frame to set custom path
// Format: [cmd][pub_key x32][type][flags][path_len][path x64][name x32][Lat? x4, Lon? x4][timestamp? x4]
//
// [hopCount] is a HOP count and [hashWidth] the bytes per hop hash; the two are
// packed into the single wire path_len byte via encodePathLen().
//
// This previously wrote the count raw, leaving the mode bits 00, which tells
// the radio "1-byte hashes". On a 2-byte net that handed the firmware 2-byte
// hash data labelled as 1-byte hops, so it routed to nodes that were never on
// the route. That is the send-side half of #240's misrouting. (#309)
Uint8List buildUpdateContactPathFrame(
  Uint8List pubKey,
  Uint8List path,
  int hopCount, {
  int hashWidth = 1,
  int type = 1, // ADV_TYPE_CHAT
  int flags = 0,
  String name = '',
  double? lat,
  double? lon,
  DateTime? lastModified,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdAddUpdateContact);
  writer.writeBytes(pubKey);
  writer.writeByte(type);
  writer.writeByte(flags);
  // Negative = flood sentinel, passed through as the firmware's 0xFF.
  writer.writeByte(hopCount < 0 ? 0xFF : encodePathLen(hopCount, hashWidth));

  writer.writeBytesPadded(path, maxPathSize);

  // Name (32 bytes, null-padded)
  writer.writeCString(name, maxNameSize);

  // Timestamp
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  writer.writeUInt32LE(timestamp);

  // Optional [Lat x4, Lon x4][timestamp x4] tail per the doc comment above.
  // Emit 8 bytes of position (zero-filled when only lastModified is provided)
  // followed by an optional 4-byte timestamp. Earlier code emitted the
  // position block twice, which corrupted the tail and caused the firmware
  // to parse the second lat as the timestamp. See #427.
  final hasLocation = lat != null && lon != null;
  if (hasLocation || lastModified != null) {
    writer.writeInt32LE(hasLocation ? (lat * 1e6).round() : 0);
    writer.writeInt32LE(hasLocation ? (lon * 1e6).round() : 0);
    if (lastModified != null) {
      final lastModifiedTimestamp = lastModified.millisecondsSinceEpoch ~/ 1000;
      writer.writeUInt32LE(lastModifiedTimestamp);
    }
  }

  return writer.toBytes();
}

// Build CMD_GET_CONTACT_BY_KEY frame
// Format: [cmd][pub_key x32]
Uint8List buildGetContactByKeyFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdGetContactByKey);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

//Build CMD_GET_CUSTOM_VARS frame
Uint8List buildGetCustomVarsFrame() {
  return Uint8List.fromList([cmdGetCustomVar]);
}

Uint8List buildGetAutoAddFlagsFrame() {
  return Uint8List.fromList([cmdGetAutoAddConfig]);
}

// Calculate LoRa airtime for a packet
// Based on Semtech SX127x datasheet formula
// Returns airtime in milliseconds
int calculateLoRaAirtime({
  required int payloadBytes,
  required int spreadingFactor,
  required int bandwidthHz,
  required int codingRate,
  int preambleSymbols = 8,
  bool lowDataRateOptimize = false,
  bool explicitHeader = true,
}) {
  // Symbol duration (Ts) in milliseconds
  final symbolDuration = (1 << spreadingFactor) / (bandwidthHz / 1000.0);

  // Preamble time
  final preambleTime = (preambleSymbols + 4.25) * symbolDuration;

  // Payload symbol count
  final headerBytes = explicitHeader ? 0 : 20;
  final crc = 1; // CRC enabled
  final de = lowDataRateOptimize ? 1 : 0;

  final numerator =
      8 * payloadBytes - 4 * spreadingFactor + 28 + 16 * crc - headerBytes;
  final denominator = 4 * (spreadingFactor - 2 * de);
  var payloadSymbols =
      8 + ((numerator / denominator).ceil()) * (codingRate + 4);

  if (payloadSymbols < 0) {
    payloadSymbols = 8;
  }

  final payloadTime = payloadSymbols * symbolDuration;

  return (preambleTime + payloadTime).ceil();
}

// Calculate timeout for a message based on radio settings
// Returns timeout in milliseconds
int calculateMessageTimeout({
  required int freqHz,
  required int bwHz,
  required int sf,
  required int cr,
  required int pathLength,
  int messageBytes = 100, // Average message size
}) {
  // Calculate airtime for one packet
  final airtime = calculateLoRaAirtime(
    payloadBytes: messageBytes,
    spreadingFactor: sf,
    bandwidthHz: bwHz,
    codingRate: cr,
    lowDataRateOptimize: sf >= 11,
  );

  if (pathLength < 0) {
    // Flood mode: Base delay + 16× airtime
    return 500 + (16 * airtime);
  } else {
    // Direct path: Base delay + ((airtime×6 + 250ms)×(hops+1))
    return 500 + ((airtime * 6 + 250) * (pathLength + 1));
  }
}

// Build CLI command text message frame (companion_radio format)
// Format: [cmd][txt_type][attempt][timestamp x4][pub_key_prefix x6][text...]\0
Uint8List buildSendCliCommandFrame(
  Uint8List repeaterPubKey,
  String command, {
  int attempt = 0,
  int? timestampSeconds,
}) {
  final timestamp =
      timestampSeconds ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final writer = BufferWriter();
  writer.writeByte(cmdSendTxtMsg);
  writer.writeByte(txtTypeCliData);
  writer.writeByte(attempt.clamp(0, 255));
  writer.writeUInt32LE(timestamp);
  writer.writeBytes(repeaterPubKey.sublist(0, 6));
  writer.writeString(command);
  writer.writeByte(0);
  return writer.toBytes();
}

// Build a telemetry request frame
// Format: [cmd][pub_key x32][payload]
Uint8List buildSendBinaryReq(Uint8List repeaterPubKey, {Uint8List? payload}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendBinaryReq);
  writer.writeBytes(repeaterPubKey);
  if (payload != null && payload.isNotEmpty) {
    writer.writeBytes(payload);
  }
  return writer.toBytes();
}

//Build a trace request frame
//[cmd][tag x4][auth x4][flag][payload]
Uint8List buildTraceReq(int tag, int auth, int flag, {Uint8List? payload}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendTracePath);
  writer.writeUInt32LE(tag);
  writer.writeUInt32LE(auth);
  writer.writeByte(flag);
  if (payload != null && payload.isNotEmpty) {
    writer.writeBytes(payload);
  }
  return writer.toBytes();
}

// Build a export contact frame
// [cmd][pub_key x32 / if empty exports your contact info]
Uint8List buildExportContactFrame(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdExportContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

// Build a import contact frame
// [cmd][contact_frame x98+]
Uint8List buildImportContactFrame(Uint8List contactFrame) {
  final writer = BufferWriter();
  writer.writeByte(cmdImportContact);
  writer.writeBytes(contactFrame);
  return writer.toBytes();
}

// Build a export contact frame
// [cmd][pub_key x32]
Uint8List buildZeroHopContact(Uint8List pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdShareContact);
  writer.writeBytes(pubKey);
  return writer.toBytes();
}

// Build CMD_SET_OTHER_PARAMS frame
// Format: [cmd][allowTelemetryFlags][advertLocationPolicy][multiAcks]
Uint8List buildSetOtherParamsFrame(
  int allowTelemetryFlags,
  int advertLocationPolicy,
  int multiAcks,
) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetOtherParams);
  //Going forward the app will just set Auto Add Contacts to disabled, and use the filter flags
  //Allow Auto Add Contacts use inverted logic (0x01 = disabled, 0x00 = enabled).
  writer.writeByte(0x01);
  writer.writeByte(allowTelemetryFlags); // Allow Telemetry Flags
  writer.writeByte(advertLocationPolicy); // Advertisement Location Policy
  writer.writeByte(multiAcks); // Multi Acknowledgements
  return writer.toBytes();
}

// Build CMD_SET_AUTO_ADD_CONFIG frame
// Format: [cmd][flags]
Uint8List buildSetAutoAddConfigFrame({
  required bool autoAddChat,
  required bool autoAddRepeater,
  required bool autoAddRoomServer,
  required bool autoAddSensor,
  required bool overwriteOldest,
}) {
  final writer = BufferWriter();
  writer.writeByte(cmdSetAutoAddConfig);
  int flags = 0;
  if (autoAddChat) flags |= autoAddChatFlag;
  if (autoAddRepeater) flags |= autoAddRepeaterFlag;
  if (autoAddRoomServer) flags |= autoAddRoomServerFlag;
  if (autoAddSensor) flags |= autoAddSensorFlag;
  if (overwriteOldest) flags |= autoAddOverwriteOldestFlag;
  writer.writeByte(flags);
  return writer.toBytes();
}

//Build CMD_SEND_TELEMETRY_REQ
// Format: [cmd][reserved x3][pub_key? x32]
Uint8List buildSendTelemetryReq(Uint8List? pubKey) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendTelemetryReq);

  if (pubKey != null && pubKey.length == pubKeySize) {
    writer.writeBytes(Uint8List(3)); // reserved bytes
    writer.writeBytes(pubKey);
  } else {
    writer.writeBytes(Uint8List(3)); // self: [cmd]+3 reserved => len==4 (#110)
  }
  return writer.toBytes();
}
