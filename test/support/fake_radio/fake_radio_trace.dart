import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fake_radio.dart';
import 'fake_radio_codes.dart';
import 'fake_radio_profile.dart';
import 'fake_radio_seed.dart';

/// A recorded session with a radio (#776): each request and the reply frames
/// it got, from `tool/fake_radio/capture_trace.py` on real hardware or from
/// [FakeRadioTrace.record] on the fake.
class FakeRadioTrace {
  FakeRadioTrace({required this.label, required this.steps});

  factory FakeRadioTrace.parse(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['format'] != 'offband-radio-trace' ||
        json['format_version'] != 1) {
      throw FormatException('not a v1 radio trace: ${json['format']}');
    }
    Uint8List hex(Object? s) {
      final str = s as String;
      return Uint8List.fromList([
        for (var i = 0; i < str.length; i += 2)
          int.parse(str.substring(i, i + 2), radix: 16),
      ]);
    }

    return FakeRadioTrace(
      label: json['label'] as String,
      steps: [
        for (final s in json['steps'] as List)
          FakeTraceStep(
            request: hex((s as Map)['request']),
            replies: [for (final r in s['replies'] as List) hex(r)],
          ),
      ],
    );
  }

  factory FakeRadioTrace.load(String path) =>
      FakeRadioTrace.parse(File(path).readAsStringSync());

  /// Runs [requests] through [radio] and records what it answers.
  factory FakeRadioTrace.record(
    FakeRadio radio,
    List<Uint8List> requests, {
    String label = 'fake',
  }) => FakeRadioTrace(
    label: label,
    steps: [
      for (final r in requests)
        FakeTraceStep(request: r, replies: radio.handle(r)),
    ],
  );

  final String label;
  final List<FakeTraceStep> steps;

  String toJson() => const JsonEncoder.withIndent(' ').convert({
    'format': 'offband-radio-trace',
    'format_version': 1,
    'label': label,
    'steps': [
      for (final s in steps)
        {
          'request': _hex(s.request),
          'replies': [for (final r in s.replies) _hex(r)],
          'pushes': <String>[],
        },
    ],
  });

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Iterable<Uint8List> _replies(int code) =>
      steps.expand((s) => s.replies).where((r) => r.isNotEmpty && r[0] == code);

  /// The profile the recorded radio reported in DEVICE_INFO.
  FakeRadioProfile profile() {
    final info = _replies(fwRespDeviceInfo).first;
    final offband = info.length > 82;
    int at(int i) => i < info.length ? info[i] : 0;
    final gps = _replies(fwOffbandGps).firstOrNull;
    var gpsText = 'detected=0';
    if (gps != null) {
      final text = _cstr(gps, 1, gps.length - 1);
      final space = text.indexOf(' ');
      gpsText = space < 0 ? '' : text.substring(space + 1);
    }
    return FakeRadioProfile(
      name: label,
      firmwareVerCode: info[1],
      versionString: _cstr(info, 60, 20),
      offband: offband,
      offbandCaps: at(82),
      femLnaEnabled: at(83) != 0,
      offbandCaps2: at(84),
      ledEnabled: at(85),
      displayMode: at(86),
      gpsStatusText: gpsText,
      deviceInfoTailBytes: offband ? info.length - 82 : 0,
    );
  }

  /// A seed that makes the fake hold what the recorded radio held.
  FakeRadioSeed seed() {
    final info = _replies(fwRespDeviceInfo).first;
    final self = _replies(fwRespSelfInfo).first;
    final bd = ByteData.sublistView(self);
    final batt = _replies(fwRespBattAndStorage).firstOrNull;
    final time = _replies(fwRespCurrTime).firstOrNull;
    final vars = _replies(fwRespCustomVars).firstOrNull;
    final auto = _replies(fwRespAutoAddConfig).firstOrNull;
    return FakeRadioSeed(
      name: utf8.decode(self.sublist(58), allowMalformed: true),
      publicKey: self.sublist(4, 36),
      txPowerDbm: bd.getInt8(2),
      maxTxPowerDbm: bd.getInt8(3),
      latE6: bd.getInt32(36, Endian.little),
      lonE6: bd.getInt32(40, Endian.little),
      multiAcks: self[44],
      advertLocPolicy: self[45],
      telemetryModes: self[46],
      manualAddContacts: self[47],
      freqKhz: bd.getUint32(48, Endian.little),
      bwHz: bd.getUint32(52, Endian.little),
      sf: self[56],
      cr: self[57],
      maxContacts: info[2] * 2,
      maxChannels: info[3],
      blePin: ByteData.sublistView(info).getUint32(4, Endian.little),
      buildDate: _cstr(info, 8, 12),
      manufacturer: _cstr(info, 20, 40),
      clientRepeat: info.length > 80 && info[80] != 0,
      pathHashMode: info.length > 81 ? info[81] : 0,
      batteryMillivolts: batt == null
          ? 4100
          : ByteData.sublistView(batt).getUint16(1, Endian.little),
      storageUsedKb: batt == null
          ? 12
          : ByteData.sublistView(batt).getUint32(3, Endian.little),
      storageTotalKb: batt == null
          ? 256
          : ByteData.sublistView(batt).getUint32(7, Endian.little),
      deviceTime: time == null
          ? 1790000000
          : ByteData.sublistView(time).getUint32(1, Endian.little),
      customVars: vars == null ? const {} : _vars(vars),
      autoAddConfig: auto?[1] ?? 0,
      autoAddMaxHops: auto?[2] ?? 0,
      contacts: [for (final c in _replies(fwRespContact)) _contact(c)],
      channels: [
        for (final c in _replies(fwRespChannelInfo))
          FakeChannel(
            index: c[1],
            name: _cstr(c, 2, 32),
            secret: c.sublist(34, 50),
          ),
      ],
    );
  }

  /// Keys the recorded radio listed in its Offband block list.
  List<Uint8List> blockedKeys() => [
    for (final f in _replies(fwOffbandBlock))
      if (f.length >= 3 + fwPubKeySize && f[1] == fwBlockList && f[2] < 0xFE)
        f.sublist(3, 3 + fwPubKeySize),
  ];

  /// A fake radio holding what the recorded radio held.
  FakeRadio radio() =>
      FakeRadio(seed: seed(), profile: profile())
        ..blockedKeys.addAll(blockedKeys());

  /// Replays every request into [radio] and lists where its replies differ
  /// from the recorded ones. Channel names are compared up to their NUL:
  /// firmware fills that field with `strcpy`, so bytes past it are leftovers.
  List<String> replay(FakeRadio radio) {
    final diffs = <String>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final got = radio.handle(s.request);
      final want = s.replies;
      final name = 'step $i (request ${_hex(s.request.take(2).toList())})';
      if (got.length != want.length) {
        diffs.add('$name: ${got.length} replies, recorded ${want.length}');
        continue;
      }
      for (var j = 0; j < got.length; j++) {
        if (_hex(_normalize(got[j])) != _hex(_normalize(want[j]))) {
          diffs.add(
            '$name reply $j:\n  fake     ${_hex(got[j])}\n'
            '  recorded ${_hex(want[j])}',
          );
        }
      }
    }
    return diffs;
  }

  static Uint8List _normalize(Uint8List f) {
    if (f.isEmpty || f[0] != fwRespChannelInfo || f.length < 34) return f;
    final out = Uint8List.fromList(f);
    final nul = out.indexOf(0, 2);
    if (nul >= 0 && nul < 34) out.fillRange(nul, 34, 0);
    return out;
  }

  static FakeContact _contact(Uint8List c) {
    final bd = ByteData.sublistView(c);
    final pathLen = c[35];
    return FakeContact(
      publicKey: c.sublist(1, 33),
      type: c[33],
      flags: c[34],
      outPathLength: pathLen == 0xFF ? -1 : pathLen,
      outPath: c.sublist(36, 36 + fwMaxPathSize),
      name: _cstr(c, 100, 32),
      lastAdvert: bd.getUint32(132, Endian.little),
      latE6: bd.getInt32(136, Endian.little),
      lonE6: bd.getInt32(140, Endian.little),
      lastmod: bd.getUint32(144, Endian.little),
    );
  }

  static Map<String, String> _vars(Uint8List f) {
    final text = utf8.decode(f.sublist(1), allowMalformed: true);
    return {
      for (final pair in text.split(',').where((p) => p.contains(':')))
        pair.substring(0, pair.indexOf(':')): pair.substring(
          pair.indexOf(':') + 1,
        ),
    };
  }

  static String _cstr(Uint8List b, int at, int width) {
    final end = at + width > b.length ? b.length : at + width;
    final field = b.sublist(at, end);
    final nul = field.indexOf(0);
    return utf8.decode(
      nul < 0 ? field : field.sublist(0, nul),
      allowMalformed: true,
    );
  }
}

class FakeTraceStep {
  FakeTraceStep({required this.request, required this.replies});

  final Uint8List request;
  final List<Uint8List> replies;
}

/// The read-only requests `capture_trace.py` sends, in the same order, so a
/// fake session and a real capture line up step for step.
List<Uint8List> captureRequests({int channels = 8}) => [
  Uint8List.fromList([fwCmdDeviceQuery, 3]),
  Uint8List.fromList([
    fwCmdAppStart,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...utf8.encode('offband-trace'),
  ]),
  Uint8List.fromList([fwCmdGetDeviceTime]),
  Uint8List.fromList([fwCmdGetBattAndStorage]),
  Uint8List.fromList([fwCmdGetCustomVars]),
  Uint8List.fromList([fwCmdGetAutoAddConfig]),
  Uint8List.fromList([fwCmdGetContacts]),
  for (var i = 0; i < channels; i++) Uint8List.fromList([fwCmdGetChannel, i]),
  Uint8List.fromList([0x7E]),
  Uint8List.fromList([fwOffbandGps]),
  Uint8List.fromList([fwOffbandBlock, fwBlockList]),
  Uint8List.fromList([fwOffbandPktHash, fwPktHashGet]),
];
