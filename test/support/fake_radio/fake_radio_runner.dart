import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fake_radio.dart';
import 'fake_radio_codes.dart';
import 'fake_radio_profile.dart';
import 'fake_radio_seed.dart';
import 'fake_radio_tcp.dart';
import 'fake_radio_trace.dart';
import 'fake_remote_node.dart';

// Pure Dart: what `dart run tool/fake_radio.dart` runs (#780). Format of seed
// files: tool/fake_radio/README.md.

/// A fake radio serving TCP, with its clock following real time so ACKs and
/// remote replies arrive while someone uses the app against it.
class FakeRadioRunner {
  FakeRadioRunner._(this.radio, this.server, this._ticker);

  static Future<FakeRadioRunner> start({
    required FakeRadio radio,
    InternetAddress? address,
    int port = 5000,
    Duration tick = const Duration(milliseconds: 100),
  }) async {
    final server = await FakeRadioTcpServer.start(
      radio,
      address: address ?? InternetAddress.anyIPv4,
      port: port,
    );
    final ticker = Timer.periodic(tick, (_) => radio.clock.advance(tick));
    return FakeRadioRunner._(radio, server, ticker);
  }

  final FakeRadio radio;
  final FakeRadioTcpServer server;
  final Timer _ticker;

  /// Handles one console line; returns what to print.
  String command(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '';
    switch (parts.first) {
      case 'dm' when parts.length >= 3:
        final name = parts[1];
        final from = radio.contacts.where((c) => c.name == name).firstOrNull;
        if (from == null) return 'no contact named "$name"';
        radio.receiveDirect(from, parts.sublist(2).join(' '));
        return 'queued a DM from $name';
      case 'chan' when parts.length >= 3:
        final index = int.tryParse(parts[1]);
        if (index == null || !radio.channels.containsKey(index)) {
          return 'no channel ${parts[1]}';
        }
        radio.receiveChannel(index, parts.sublist(2).join(' '));
        return 'queued a message on channel $index';
      case 'drop':
        radio.dropConnection();
        return 'dropped the link';
      case 'status':
        return '${radio.profile.name} on ${server.host}:${server.port}, '
            '${server.clients} client(s), ${radio.received.length} commands, '
            '${radio.offlineQueue.length} queued';
      case 'help':
        return 'dm <contact> <text> | chan <index> <text> | drop | status | quit';
      default:
        return 'unknown: "$line" (try help)';
    }
  }

  Future<void> close() async {
    _ticker.cancel();
    await server.close();
    await radio.close();
  }
}

/// Builds the radio from a seed file or a captured trace (see README), or
/// the default seed when [path] is null.
FakeRadio fakeRadioFromFile(String? path, {required String profile}) {
  FakeRadioProfile pick() => switch (profile) {
    'offband' => FakeRadioProfile.offband(),
    'stock' => FakeRadioProfile.stock(),
    _ => throw ArgumentError('profile must be offband or stock: $profile'),
  };
  if (path == null) {
    return FakeRadio(
      profile: pick(),
      seed: FakeRadioSeed(
        contacts: [FakeContact.keyed(0x11, 'Alpha')],
        channels: [FakeChannel(index: 0, name: 'Public')],
      ),
    );
  }
  final text = File(path).readAsStringSync();
  final json = jsonDecode(text) as Map<String, dynamic>;
  if (json['format'] == 'offband-radio-trace') {
    return FakeRadioTrace.parse(text).radio();
  }
  return parseFakeRadioSeedFile(json, profile: pick());
}

/// `offband-fake-radio-seed` v1 (tool/fake_radio/README.md).
FakeRadio parseFakeRadioSeedFile(
  Map<String, dynamic> json, {
  required FakeRadioProfile profile,
}) {
  if (json['format'] != 'offband-fake-radio-seed' ||
      json['format_version'] != 1) {
    throw FormatException('not a v1 fake radio seed: ${json['format']}');
  }
  Uint8List hex(String s) => Uint8List.fromList([
    for (var i = 0; i + 1 < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
  Uint8List key(String s) => s.length == 2
      ? Uint8List.fromList(
          List<int>.filled(fwPubKeySize, int.parse(s, radix: 16)),
        )
      : hex(s);
  const types = {
    'chat': fwAdvTypeChat,
    'repeater': fwAdvTypeRepeater,
    'room': fwAdvTypeRoom,
    'sensor': fwAdvTypeSensor,
  };

  final contacts = <FakeContact>[
    for (final c
        in (json['contacts'] as List? ?? []).cast<Map<String, dynamic>>())
      FakeContact(
        publicKey: key(c['key'] as String),
        name: c['name'] as String,
        type:
            types[c['type'] ?? 'chat'] ??
            (throw FormatException('unknown contact type ${c['type']}')),
        outPathLength: c['path'] == null
            ? -1
            : (c['path'] as String).length ~/ 2,
        outPath: c['path'] == null ? null : hex(c['path'] as String),
      ),
  ];
  final radio = FakeRadio(
    profile: profile,
    seed: FakeRadioSeed(
      name: json['name'] as String? ?? 'Fake Radio',
      freqKhz: json['freq_khz'] as int? ?? 910525,
      bwHz: json['bw_hz'] as int? ?? 62500,
      sf: json['sf'] as int? ?? 7,
      cr: json['cr'] as int? ?? 5,
      txPowerDbm: json['tx_power'] as int? ?? 20,
      contacts: contacts,
      channels: [
        for (final c
            in (json['channels'] as List? ?? []).cast<Map<String, dynamic>>())
          FakeChannel(
            index: c['index'] as int,
            name: c['name'] as String,
            secret: c['secret'] == null ? null : hex(c['secret'] as String),
          ),
      ],
    ),
  );
  for (final n
      in (json['remote_nodes'] as List? ?? []).cast<Map<String, dynamic>>()) {
    final contact = contacts.firstWhere(
      (c) => c.name == n['contact'],
      orElse: () =>
          throw FormatException('remote node ${n['contact']} is not a contact'),
    );
    radio.addRemoteNode(
      FakeRemoteNode(
        contact: contact,
        adminPassword: n['admin_password'] as String? ?? 'password',
        guestPassword: n['guest_password'] as String? ?? '',
        offband: (n['firmware'] as String? ?? 'offband') == 'offband',
      ),
    );
  }
  return radio;
}
