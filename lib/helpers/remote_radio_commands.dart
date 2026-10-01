import '../models/radio_preset.dart';

// Radio presets on remote nodes (repeater, room server, sensor) through the
// stock admin CLI (#733). Kept out of the screen so it can be tested.

/// The preset whose radio values match the form's, or null for custom values.
/// The form holds frequency as text (the repeater reports e.g. "908.205017"),
/// so frequency matches to the nearest kHz. TX power is not compared: the
/// remote screen sets it separately.
String? matchRemotePresetId(
  List<RadioPreset> presets, {
  required String frequencyText,
  required int? bandwidthHz,
  required int? spreadingFactor,
  required int? codingRate,
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
        p.codingRate.value == codingRate) {
      return p.id;
    }
  }
  return null;
}
