import '../models/radio_preset.dart';

// Radio presets on remote nodes (repeater, room server, sensor) through the
// stock admin CLI (#733). Kept out of the screen so it can be tested.

/// Default `tempradio` duration (owner decision on #662).
const int kTempRadioDefaultMinutes = 1440;

/// Longest `tempradio` duration that works. Firmware schedules the revert at
/// `futureMillis(2000 + timeout_mins * 60 * 1000)` in a 32-bit int
/// (simple_repeater/MyMesh.cpp), which overflows past this.
const int kTempRadioMaxMinutes = 35791;

String _bandwidthKHz(int bandwidthHz) => '${bandwidthHz / 1000}';

/// Stock CLI: persist radio params (applied after a reboot).
String setRadioCommand(
  String frequencyText,
  int bandwidthHz,
  int spreadingFactor,
  int codingRate,
) =>
    'set radio $frequencyText,${_bandwidthKHz(bandwidthHz)},'
    '$spreadingFactor,$codingRate';

/// Stock CLI: apply radio params now, reverting after [minutes]. Nothing is
/// saved on the node. Coding rate is the 4/x denominator (4/5 is 5), which
/// is what firmware range-checks (5-8).
String tempRadioCommand(
  String frequencyText,
  int bandwidthHz,
  int spreadingFactor,
  int codingRate,
  int minutes,
) =>
    'tempradio $frequencyText,${_bandwidthKHz(bandwidthHz)},'
    '$spreadingFactor,$codingRate,$minutes';

/// A valid `tempradio` duration in minutes (1 to [kTempRadioMaxMinutes]),
/// or null.
int? parseTempRadioMinutes(String text) {
  final minutes = int.tryParse(text.trim());
  if (minutes == null || minutes < 1 || minutes > kTempRadioMaxMinutes) {
    return null;
  }
  return minutes;
}

/// `tempradio` retunes the node 2 s after it replies, so anything sent after
/// it in the same save would go out on the old frequency. Keep the original
/// order otherwise, with retuning commands moved to the end.
List<T> withRetuneLast<T>(List<T> commands, bool Function(T) retunes) => [
  ...commands.where((c) => !retunes(c)),
  ...commands.where(retunes),
];

bool isRetuneCommand(String command) => command.startsWith('tempradio ');

/// Stock CLI: path hash mode, zero-based (2 bytes = mode 1).
String setPathHashModeCommand(int mode) => 'set path.hash.mode $mode';

/// Whether a path hash that came from a preset goes out in this save (#735).
/// Firmware has no temporary path hash, so with a temporary radio change it
/// would outlive the revert; it stays pending for a normal save instead. A
/// path hash the user set by hand is always sent.
bool sendsPresetPathHash({
  required bool temporaryRadio,
  required bool pathHashFromPreset,
}) => !(temporaryRadio && pathHashFromPreset);

/// The preset whose radio values match the form's, or null for custom values.
/// The form holds frequency as text (the repeater reports e.g. "908.205017"),
/// so frequency matches to the nearest kHz. TX power is not compared: the
/// remote screen sets it separately. A preset with a path hash only matches
/// a node on that mode (#747): MeshCore's "Canada" and "USA" differ only there.
String? matchRemotePresetId(
  List<RadioPreset> presets, {
  required String frequencyText,
  required int? bandwidthHz,
  required int? spreadingFactor,
  required int? codingRate,
  required int pathHashMode,
}) {
  final mhz = double.tryParse(frequencyText.trim());
  if (mhz == null ||
      bandwidthHz == null ||
      spreadingFactor == null ||
      codingRate == null) {
    return null;
  }
  final khz = (mhz * 1000).round();
  for (final p in presets) {
    if (p.frequencyKHz == khz &&
        p.bandwidth.hz == bandwidthHz &&
        p.spreadingFactor.value == spreadingFactor &&
        p.codingRate.value == codingRate &&
        presetPathHashMatches(p, pathHashMode + 1)) {
      return p.id;
    }
  }
  return null;
}
