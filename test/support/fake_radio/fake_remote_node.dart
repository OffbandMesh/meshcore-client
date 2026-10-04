import 'fake_radio_seed.dart';

/// A repeater, room server or sensor out on the mesh, reached through the
/// companion with login and CLI commands (#774). Its CLI replies are copied
/// from firmware `src/helpers/CommonCLI.cpp`; [offband] picks the Offband or
/// stock (upstream `companion-v1.17.1`) behavior where they differ.
class FakeRemoteNode {
  FakeRemoteNode({
    required this.contact,
    this.adminPassword = 'password',
    this.guestPassword = '',
    this.offband = true,
    this.freqMhz = 910.525,
    this.bwKhz = 62.5,
    this.sf = 7,
    this.cr = 5,
    this.txPowerDbm = 20,
    this.pathHashMode = 0,
    this.firmwareVersion = 'v1.17.0',
    this.buildDate = '1 Oct 2026',
    this.offbandVersion = 'offband-v1.5.0-beta7',
    this.replyDelay = const Duration(seconds: 1),
  });

  final FakeContact contact;
  final String adminPassword;
  final String guestPassword;
  final bool offband;

  // Saved prefs. `set radio` writes these; they apply after a reboot.
  double freqMhz;
  double bwKhz;
  int sf;
  int cr;
  int txPowerDbm;
  int pathHashMode;

  final String firmwareVersion;
  final String buildDate;
  final String offbandVersion;

  /// How long a login or CLI reply takes to come back, on the fake clock.
  Duration replyDelay;

  /// The temporary radio from `tempradio`, while it lasts.
  FakeTempRadio? tempRadio;

  /// Every CLI command received, in order.
  final List<String> commands = [];

  /// `handleLoginReq` (examples/simple_repeater/MyMesh.cpp:93-120): admin
  /// password, guest password, or no reply at all.
  FakeLoginResult? login(String password) {
    if (password == adminPassword) return FakeLoginResult.admin;
    if (password == guestPassword) return FakeLoginResult.guest;
    return null;
  }

  /// One CLI command, its reply text. A `tempradio` leaves its settings in
  /// [takePendingTempRadio] for the radio to schedule.
  String command(String text) {
    commands.add(text);
    if (offband && _word(text, 'version')) {
      // CommonCLI.cpp:650-657 (Offband identity, FF3 / #180).
      return 'Upstream MeshCore: $firmwareVersion ($buildDate)\n'
          'Offband fork: $offbandVersion (sha 0000000, main, built $buildDate)';
    }
    if (text.startsWith('ver')) {
      // CommonCLI.cpp:750-751. Stock has no `version`, so it lands here too.
      return '$firmwareVersion (Build: $buildDate)';
    }
    if (text.startsWith('tempradio ')) return _tempRadio(text.substring(10));
    if (text.startsWith('get ')) return _get(text.substring(4));
    if (text.startsWith('set ')) return _set(text.substring(4));
    return 'Unknown command';
  }

  /// `tempradio f,bw,sf,cr,mins` (CommonCLI.cpp:719-733).
  String _tempRadio(String args) {
    final p = args.split(',');
    final f = p.isNotEmpty ? _float(p[0]) : 0.0;
    final bw = p.length > 1 ? _float(p[1]) : 0.0;
    final s = p.length > 2 ? _int(p[2]) : 0;
    final c = p.length > 3 ? _int(p[3]) : 0;
    final mins = p.length > 4 ? _int(p[4]) : 0;
    if (!_validRadio(f, bw, s, c) || mins <= 0) return 'Error, invalid params';
    _pendingTemp = FakeTempRadio(f, bw, s, c, mins);
    return 'OK - temp params for $mins mins';
  }

  FakeTempRadio? _pendingTemp;

  /// The `tempradio` the last command asked for, if any (taken once).
  FakeTempRadio? takePendingTempRadio() {
    final t = _pendingTemp;
    _pendingTemp = null;
    return t;
  }

  /// `handleGetCmd` (CommonCLI.cpp:1653-1697).
  String _get(String key) => switch (key.trim()) {
    'radio' => '> ${_ftoa3(freqMhz)},${_ftoa3(bwKhz)},$sf,$cr',
    'tx' => '> $txPowerDbm',
    'path.hash.mode' => '> $pathHashMode',
    'freq' => '> ${_ftoa3(freqMhz)}',
    _ => 'Unknown command',
  };

  /// `handleSetCmd` (CommonCLI.cpp:1333-1482).
  String _set(String config) {
    if (config.startsWith('radio ')) {
      final p = config.substring(6).split(',');
      // Offband (#299) rejects a fifth part; stock (parseTextParts with 4)
      // ignores anything past the fourth.
      if (offband && p.length > 4) {
        return 'Error, too many params (expected freq,bw,sf,cr)';
      }
      final f = p.isNotEmpty ? _float(p[0]) : 0.0;
      final bw = p.length > 1 ? _float(p[1]) : 0.0;
      final s = p.length > 2 ? _int(p[2]) : 0;
      final c = p.length > 3 ? _int(p[3]) : 0;
      if (!_validRadio(f, bw, s, c)) return 'Error, invalid radio params';
      freqMhz = f;
      bwKhz = bw;
      sf = s;
      cr = c;
      return 'OK - reboot to apply';
    }
    if (config.startsWith('path.hash.mode ')) {
      final mode = _int(config.substring(15));
      if (mode >= 3 || mode < 0) return 'Error, must be 0,1, or 2';
      pathHashMode = mode;
      return 'OK';
    }
    if (config.startsWith('tx ')) {
      txPowerDbm = _int(config.substring(3));
      return 'OK';
    }
    return 'Unknown command';
  }

  static bool _validRadio(double f, double bw, int s, int c) =>
      f >= 150.0 &&
      f <= 2500.0 &&
      s >= 5 &&
      s <= 12 &&
      c >= 5 &&
      c <= 8 &&
      bw >= 7.0 &&
      bw <= 500.0;

  static bool _word(String text, String w) =>
      text == w || text.startsWith('$w ');

  /// `strtof`: leading number, else 0.
  static double _float(String s) =>
      double.tryParse(
        RegExp(r'^\s*[-+]?\d*\.?\d+').firstMatch(s)?.group(0)?.trim() ?? '',
      ) ??
      0.0;

  /// `atoi`: leading integer, else 0.
  static int _int(String s) =>
      int.tryParse(
        RegExp(r'^\s*[-+]?\d+').firstMatch(s)?.group(0)?.trim() ?? '',
      ) ??
      0;

  /// `StrHelper::ftoa3` (src/helpers/TxtDataHelpers.cpp:143-154): three
  /// decimals, rounded, trailing zeros and a bare point dropped.
  static String _ftoa3(double f) {
    final v = (f * 1000 + (f >= 0 ? 0.5 : -0.5)).truncate();
    var s = '${v ~/ 1000}.${(v % 1000).abs().toString().padLeft(3, '0')}';
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }
}

enum FakeLoginResult { admin, guest }

/// A temporary radio setting from `tempradio`, reverting after [minutes].
class FakeTempRadio {
  FakeTempRadio(this.freqMhz, this.bwKhz, this.sf, this.cr, this.minutes);

  final double freqMhz;
  final double bwKhz;
  final int sf;
  final int cr;
  final int minutes;
}
