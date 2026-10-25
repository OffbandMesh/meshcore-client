import 'dart:typed_data';

import 'offband_device_ui.dart';

/// The badge's own display and battery settings over `0xC5` (#987): both
/// text sizes, Screen off, time zone and the battery full point. Gated on caps
/// byte 2 `0x40` SCREEN_SETTINGS (meshcore-firmware `f3d30a88`).
///
/// Every reply, GET or SET, is the whole set re-read after the write:
/// `[0xC5][sub][nav][msg][scr_stored:2][scr_secs:2][tz][batt_stored:2]
/// [batt_full:2][batt_pinned]`, 14 bytes, all little-endian.

const int offbandUiScreenGet = 0x13;
const int offbandUiTextSet = 0x14;
const int offbandUiScreenOffSet = 0x15;
const int offbandUiTimeZoneSet = 0x16;
const int offbandUiBatterySet = 0x17;
const int _screenReplyLength = 14;

/// The three text sizes, in firmware's encoding (`BadgeLayout.h`).
enum BadgeTextSize {
  large(0, 'Large'),
  medium(1, 'Medium'),
  small(2, 'Small');

  const BadgeTextSize(this.code, this.label);
  final int code;
  final String label;

  static BadgeTextSize? fromCode(int code) {
    for (final s in BadgeTextSize.values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// Which text size a TEXT_SET changes: the badge's Nav text or Message text.
enum BadgeTextTarget {
  navigation(0),
  messages(1);

  const BadgeTextTarget(this.code);
  final int code;
}

/// The Screen off steps the badge's row cycles through (`kScreenOffSteps`).
/// Firmware accepts exactly these and nothing else.
const List<int> screenOffSteps = [15, 30, 60, 120, 300];

String screenOffLabel(int secs) => secs < 60
    ? '$secs s'
    : '${secs ~/ 60} m${secs % 60 == 0 ? '' : ' ${secs % 60} s'}';

/// The radio's screen and battery settings, from any `0x13` to `0x17` reply.
class ScreenSettingsState {
  const ScreenSettingsState({
    required this.navText,
    required this.messageText,
    required this.screenOffStored,
    required this.screenOffSeconds,
    required this.timeZone,
    required this.batteryFullStored,
    required this.batteryFullMv,
    required this.batteryPinned,
  });

  /// Null when a newer firmware reports a size this client does not know.
  final BadgeTextSize? navText;
  final BadgeTextSize? messageText;

  /// The Screen off preference in seconds; 0 means the board's compiled
  /// timeout, which [screenOffSeconds] then reports.
  final int screenOffStored;
  final int screenOffSeconds;

  /// Index into the badge's zone table; 0 is not set.
  final int timeZone;

  /// The learned or pinned full point in mV, 0 when there is neither.
  final int batteryFullStored;

  /// The mV the radio's battery bar treats as 100%.
  final int batteryFullMv;

  /// Set by hand, which auto-learn leaves alone.
  final bool batteryPinned;

  bool get screenOffIsDefault => screenOffStored == 0;
}

Uint8List buildScreenSettingsGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiScreenGet]);

Uint8List buildTextSizeSetFrame(BadgeTextTarget target, BadgeTextSize size) =>
    Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiTextSet,
      target.code,
      size.code,
    ]);

Uint8List buildScreenOffSetFrame(int seconds) {
  if (seconds < 0 || seconds > 0xFFFF) {
    throw ArgumentError.value(seconds, 'seconds', 'must be 0 to 65535');
  }
  return Uint8List.fromList([
    cmdOffbandDeviceUi,
    offbandUiScreenOffSet,
    seconds & 0xFF,
    seconds >> 8,
  ]);
}

Uint8List buildTimeZoneSetFrame(int index) {
  if (index < 0 || index > 0xFF) {
    throw ArgumentError.value(index, 'index', 'must be 0 to 255');
  }
  return Uint8List.fromList([cmdOffbandDeviceUi, offbandUiTimeZoneSet, index]);
}

/// `pin` true pins the radio's own current reading as 100%; false hands the
/// full point back to auto-learn.
Uint8List buildBatteryFullSetFrame({required bool pin}) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiBatterySet, pin ? 1 : 0]);

/// Parse a screen-settings reply. Null if this is not one, or if it is
/// shorter than the 14 bytes the contract fixes. The shared 0x7F error is
/// owned by [parseButtonMatrixReply].
OffbandUiReply? parseScreenSettingsReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];
  if (sub < offbandUiScreenGet || sub > offbandUiBatterySet) return null;
  if (frame.length < _screenReplyLength) return null;
  final data = ByteData.sublistView(frame);
  return OffbandUiReply(
    command: respCodeOffbandDeviceUi,
    sub: sub,
    screen: ScreenSettingsState(
      navText: BadgeTextSize.fromCode(frame[2]),
      messageText: BadgeTextSize.fromCode(frame[3]),
      screenOffStored: data.getUint16(4, Endian.little),
      screenOffSeconds: data.getUint16(6, Endian.little),
      timeZone: frame[8],
      batteryFullStored: data.getUint16(9, Endian.little),
      batteryFullMv: data.getUint16(11, Endian.little),
      batteryPinned: frame[13] != 0,
    ),
  );
}
