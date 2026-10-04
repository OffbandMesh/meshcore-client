import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'fake_clock.dart';
import 'fake_radio_codes.dart';
import 'fake_radio_profile.dart';
import 'fake_radio_seed.dart';

/// A MeshCore companion radio in software, for tests (#755).
///
/// [handle] takes one command frame (the payload the client writes) and
/// returns the radio's immediate reply frames, in firmware order. Frames the
/// radio sends on its own (pushes) go to [pushes]. Every reply is built the way
/// the named firmware function builds it, in
/// OffbandMesh/meshcore-firmware `examples/companion_radio/MyMesh.cpp`.
class FakeRadio {
  FakeRadio({FakeRadioSeed? seed, FakeRadioProfile? profile, FakeClock? clock})
    : seed = seed ?? FakeRadioSeed(),
      profile = profile ?? FakeRadioProfile.offband(),
      clock = clock ?? FakeClock() {
    final s = this.seed;
    name = s.name;
    txPowerDbm = s.txPowerDbm;
    freqKhz = s.freqKhz;
    bwHz = s.bwHz;
    sf = s.sf;
    cr = s.cr;
    clientRepeat = s.clientRepeat;
    pathHashMode = s.pathHashMode;
    latE6 = s.latE6;
    lonE6 = s.lonE6;
    multiAcks = s.multiAcks;
    advertLocPolicy = s.advertLocPolicy;
    telemetryModes = s.telemetryModes;
    manualAddContacts = s.manualAddContacts;
    autoAddConfig = s.autoAddConfig;
    autoAddMaxHops = s.autoAddMaxHops;
    customVars.addAll(s.customVars);
    contacts.addAll(s.contacts);
    for (final c in s.channels) {
      channels[c.index] = c;
    }
    this.clock.epochSeconds = s.deviceTime;
  }

  final FakeRadioSeed seed;
  final FakeRadioProfile profile;
  final FakeClock clock;

  // Live state, starting from the seed. Commands change it as firmware would.
  late String name;
  late int txPowerDbm;
  late int freqKhz;
  late int bwHz;
  late int sf;
  late int cr;
  late bool clientRepeat;
  late int pathHashMode;
  late int latE6;
  late int lonE6;
  late int multiAcks;
  late int advertLocPolicy;
  late int telemetryModes;
  late int manualAddContacts;
  late int autoAddConfig;
  late int autoAddMaxHops;
  final Map<String, String> customVars = {};
  final List<FakeContact> contacts = [];
  final Map<int, FakeChannel> channels = {};

  /// The Offband user-block list (0xC2), as public keys.
  final List<Uint8List> blockedKeys = [];

  /// `MAX_BLOCKED_KEYS` (src/helpers/BlockStore.h:20).
  static const int maxBlockedKeys = 32;

  /// Frames waiting for CMD_SYNC_NEXT_MESSAGE (the firmware's offline queue).
  final List<Uint8List> offlineQueue = [];

  /// Every command frame received, in order, for assertions.
  final List<Uint8List> received = [];

  final StreamController<Uint8List> _pushes =
      StreamController<Uint8List>.broadcast(sync: true);

  /// Frames the radio sends unprompted.
  Stream<Uint8List> get pushes => _pushes.stream;

  void push(Uint8List frame) => _pushes.add(frame);

  Future<void> close() => _pushes.close();

  /// Replies to one command frame, in the order the firmware writes them.
  List<Uint8List> handle(Uint8List cmd) {
    received.add(Uint8List.fromList(cmd));
    if (cmd.isEmpty) return [];
    final len = cmd.length;
    if (profile.offband && cmd[0] >= fwOffbandConfig && cmd[0] <= 0xCF) {
      return _offband(cmd);
    }
    switch (cmd[0]) {
      case fwCmdDeviceQuery when len >= 2:
        return [deviceInfoFrame()];
      case fwCmdAppStart when len >= 8:
        return [selfInfoFrame()];
      case fwCmdGetContacts:
        return _contacts(len >= 5 ? _u32At(cmd, 1) : 0);
      case fwCmdGetDeviceTime:
        return [_concat(fwRespCurrTime, _u32(clock.epochSeconds))];
      case fwCmdSetDeviceTime when len >= 5:
        // Offband (MyMesh.cpp:2765, #607) accepts any time; stock (upstream
        // a366955c MyMesh.cpp:1240) refuses one earlier than its clock.
        final t = _u32At(cmd, 1);
        if (profile.offband || t >= clock.epochSeconds) {
          clock.epochSeconds = t;
          return [okFrame()];
        }
        return [errFrame(fwErrIllegalArg)];
      case fwCmdSyncNextMessage:
        return [
          offlineQueue.isNotEmpty
              ? offlineQueue.removeAt(0)
              : Uint8List.fromList([fwRespNoMoreMessages]),
        ];
      case fwCmdGetBattAndStorage:
        return [
          Uint8List.fromList([
            fwRespBattAndStorage,
            ..._u16(seed.batteryMillivolts),
            ..._u32(seed.storageUsedKb),
            ..._u32(seed.storageTotalKb),
          ]),
        ];
      case fwCmdGetChannel when len >= 2:
        return [_channelInfo(cmd[1])];
      case fwCmdGetCustomVars:
        return [customVarsFrame()];
      case fwCmdGetAutoAddConfig:
        return [
          Uint8List.fromList([
            fwRespAutoAddConfig,
            autoAddConfig,
            autoAddMaxHops,
          ]),
        ];
      case fwCmdSetAutoAddConfig when len >= 2:
        autoAddConfig = cmd[1];
        if (len >= 3) autoAddMaxHops = cmd[2] > 64 ? 64 : cmd[2];
        return [okFrame()];
      case fwCmdSetOtherParams when len >= 2:
        // MyMesh.cpp:2974.
        manualAddContacts = cmd[1];
        if (len >= 3) telemetryModes = cmd[2];
        if (len >= 4) advertLocPolicy = cmd[3];
        if (len >= 5) multiAcks = cmd[4];
        return [okFrame()];
      case fwCmdSetAdvertName when len >= 2:
        name = utf8.decode(cmd.sublist(1), allowMalformed: true);
        if (name.length > 31) name = name.substring(0, 31);
        return [okFrame()];
      default:
        // MyMesh.cpp:3561: anything else, including Offband commands on a radio
        // that doesn't answer them, is an unsupported command.
        return [errFrame(fwErrUnsupportedCmd)];
    }
  }

  /// Offband commands. The fake answers the ones a default companion's client
  /// sends: GPS status, the block list and the packet-hash query. Config,
  /// FEM LNA, caplog and device-UI need capability bits the default profile
  /// doesn't advertise, so a client honoring the bits never sends them; the
  /// fake rejects them as unsupported rather than invent a reply.
  List<Uint8List> _offband(Uint8List cmd) {
    final len = cmd.length;
    switch (cmd[0]) {
      case fwOffbandGps:
        // MyMesh.cpp:1975-1983: "enabled=N " + board status, NUL-terminated.
        final enabled = customVars['gps'] == '1' ? 1 : 0;
        return [
          Uint8List.fromList([
            fwOffbandGps,
            ...utf8.encode('enabled=$enabled ${profile.gpsStatusText}'),
            0,
          ]),
        ];
      case fwOffbandBlock when len >= 2:
        return _block(cmd);
      case fwOffbandPktHash when len >= 2 && cmd[1] == fwPktHashGet:
        // MyMesh.cpp:2114-2133: exactly 7 bytes; the fake keeps no send ring,
        // so every well-formed query is an unknown key.
        return [
          Uint8List.fromList([
            fwOffbandPktHash,
            fwPktHashErr,
            len != 7 ? fwPktHashErrMalformed : fwPktHashErrUnknownKey,
          ]),
        ];
      default:
        return [errFrame(fwErrUnsupportedCmd)];
    }
  }

  /// 0xC2 (MyMesh.cpp:2074-2100) and its list drain (`blockListDrain`).
  List<Uint8List> _block(Uint8List cmd) {
    final sub = cmd[1];
    Uint8List ack(bool ok) =>
        Uint8List.fromList([fwOffbandBlock, sub, ok ? 1 : 0]);
    bool same(Uint8List a, List<int> b) {
      for (var i = 0; i < fwPubKeySize; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    if ((sub == fwBlockAdd || sub == fwBlockRemove) &&
        cmd.length >= 2 + fwPubKeySize) {
      // BlockStore (src/helpers/BlockStore.h:48-70): add dedups (a repeat is
      // true), fails only when full; remove swaps the last entry into the gap.
      final key = cmd.sublist(2, 2 + fwPubKeySize);
      final at = blockedKeys.indexWhere((k) => same(k, key));
      if (sub == fwBlockAdd) {
        if (at >= 0) return [ack(true)];
        if (blockedKeys.length >= maxBlockedKeys) return [ack(false)];
        blockedKeys.add(Uint8List.fromList(key));
        return [ack(true)];
      }
      if (at < 0) return [ack(false)];
      final last = blockedKeys.removeLast();
      if (at < blockedKeys.length) blockedKeys[at] = last;
      return [ack(true)];
    }
    if (sub == fwBlockClear) {
      blockedKeys.clear();
      return [ack(true)];
    }
    if (sub == fwBlockList) {
      return [
        Uint8List.fromList([fwOffbandBlock, sub, 0xFF, blockedKeys.length]),
        for (var i = 0; i < blockedKeys.length; i++)
          Uint8List.fromList([fwOffbandBlock, sub, i, ...blockedKeys[i]]),
        Uint8List.fromList([fwOffbandBlock, sub, 0xFE]),
      ];
    }
    return [errFrame(fwErrIllegalArg)];
  }

  /// `writeOKFrame` (MyMesh.cpp:258).
  static Uint8List okFrame() => Uint8List.fromList([fwRespOk]);

  /// `writeErrFrame` (MyMesh.cpp:263).
  static Uint8List errFrame(int code) => Uint8List.fromList([fwRespErr, code]);

  /// The CMD_DEVICE_QUERY reply (MyMesh.cpp:2420-2505). Stock firmware ends
  /// after path_hash_mode (byte 81); Offband appends its capability tail.
  Uint8List deviceInfoFrame() {
    final b = BytesBuilder()
      ..addByte(fwRespDeviceInfo)
      ..addByte(profile.firmwareVerCode)
      ..addByte(seed.maxContacts ~/ 2)
      ..addByte(seed.maxChannels)
      ..add(_u32(seed.blePin))
      ..add(_fixed(seed.buildDate, 12))
      ..add(_fixed(seed.manufacturer, 40))
      ..add(_fixed(profile.versionString, 20))
      ..addByte(clientRepeat ? 1 : 0)
      ..addByte(pathHashMode);
    if (profile.offband) {
      b
        ..addByte(profile.offbandCaps)
        ..addByte(profile.femLnaEnabled ? 1 : 0)
        ..addByte(profile.offbandCaps2)
        ..addByte(profile.ledEnabled)
        ..addByte(profile.displayMode);
    }
    return b.toBytes();
  }

  /// The CMD_APP_START reply (MyMesh.cpp:2553-2586).
  Uint8List selfInfoFrame() {
    final b = BytesBuilder()
      ..addByte(fwRespSelfInfo)
      ..addByte(fwAdvTypeChat)
      ..addByte(txPowerDbm & 0xFF)
      ..addByte(seed.maxTxPowerDbm & 0xFF)
      ..add(seed.publicKey)
      ..add(_i32(latE6))
      ..add(_i32(lonE6))
      ..addByte(multiAcks)
      ..addByte(advertLocPolicy)
      ..addByte(telemetryModes)
      ..addByte(manualAddContacts)
      ..add(_u32(freqKhz))
      ..add(_u32(bwHz))
      ..addByte(sf)
      ..addByte(cr)
      ..add(utf8.encode(name));
    return b.toBytes();
  }

  /// CMD_GET_CONTACTS (MyMesh.cpp:2716-2736) and the iterator that streams the
  /// list (MyMesh.cpp:3867-3879). The firmware sends one contact per loop
  /// tick; the order is the same, so the fake sends them together.
  List<Uint8List> _contacts(int since) {
    final out = <Uint8List>[
      _concat(
        fwRespContactsStart,
        _u32(contacts.length),
      ), // total, not filtered
    ];
    var mostRecent = 0;
    for (final c in contacts) {
      if (c.lastmod > since) {
        out.add(contactFrame(fwRespContact, c));
        if (c.lastmod > mostRecent) mostRecent = c.lastmod;
      }
    }
    out.add(_concat(fwRespEndOfContacts, _u32(mostRecent)));
    return out;
  }

  /// `writeContactRespFrame` (MyMesh.cpp:276-297).
  static Uint8List contactFrame(int code, FakeContact c) {
    final path = Uint8List(fwMaxPathSize)
      ..setRange(
        0,
        c.outPath.length > fwMaxPathSize ? fwMaxPathSize : c.outPath.length,
        c.outPath,
      );
    return (BytesBuilder()
          ..addByte(code)
          ..add(c.publicKey)
          ..addByte(c.type)
          ..addByte(c.flags)
          ..addByte(c.outPathLength < 0 ? 0xFF : c.outPathLength)
          ..add(path)
          ..add(_fixed(c.name, 32))
          ..add(_u32(c.lastAdvert))
          ..add(_i32(c.latE6))
          ..add(_i32(c.lonE6))
          ..add(_u32(c.lastmod)))
        .toBytes();
  }

  /// CMD_GET_CHANNEL (MyMesh.cpp:3234-3248).
  Uint8List _channelInfo(int index) {
    final c = channels[index];
    if (c == null || index >= seed.maxChannels) {
      return errFrame(fwErrNotFound);
    }
    return (BytesBuilder()
          ..addByte(fwRespChannelInfo)
          ..addByte(index)
          ..add(_fixed(c.name, 32))
          ..add(c.secret))
        .toBytes();
  }

  /// CMD_GET_CUSTOM_VARS (MyMesh.cpp:3354-3367): `name:value` pairs, comma
  /// separated, no terminator.
  Uint8List customVarsFrame() {
    final text = customVars.entries.map((e) => '${e.key}:${e.value}').join(',');
    return _concat(fwRespCustomVars, utf8.encode(text));
  }

  static Uint8List _concat(int code, List<int> body) =>
      Uint8List.fromList([code, ...body]);

  static int _u32At(Uint8List b, int offset) =>
      ByteData.sublistView(b, offset, offset + 4).getUint32(0, Endian.little);

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  static Uint8List _u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

  static Uint8List _i32(int v) =>
      Uint8List(4)..buffer.asByteData().setInt32(0, v, Endian.little);

  /// A NUL-padded fixed-width string field (`StrHelper::strzcpy`), always
  /// leaving room for the terminator.
  static Uint8List _fixed(String s, int width) {
    final out = Uint8List(width);
    final bytes = utf8.encode(s);
    final n = bytes.length < width ? bytes.length : width - 1;
    out.setRange(0, n, bytes);
    return out;
  }
}
