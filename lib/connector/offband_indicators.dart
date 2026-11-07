import 'dart:typed_data';

import 'offband_device_ui.dart';

/// The radio's display and LED over `0xC5` (#523, #944): display mode, display
/// rotation and the status LED. Gated on caps byte 2 `0x04` INDICATORS
/// (meshcore-firmware #542, rotation #1990).
///
///   display   GET `[0xC5][0x05]`        -> `[0xC5][0x05][mode]`
///             SET `[0xC5][0x06][mode]`  -> the same
///   led       GET `[0xC5][0x07]`        -> `[0xC5][0x07][on]`
///             SET `[0xC5][0x08][on]`    -> the same
///   rotation  GET `[0xC5][0x1A]`        -> `[0xC5][0x1A][deg]`
///             SET `[0xC5][0x1B][deg]`   -> the same
///
/// ROTATION IS `0x1A`/`0x1B`, NOT `0x18`/`0x19`. Those are CHNOTIFY, and this
/// file held them until 2026-11-04. The collision was not theoretical:
/// firmware `4e5a6c85`, already flashed on the owner's T1000-E, answers
/// `0x18`/`0x19` as per-channel channel-notify and its SET validates only
/// `mode < 4`, so a rotation SET of `0` landed as a valid notify-mode write on
/// channel slot 0, which is Public and undeletable, and BOTH sides reported
/// success. No error, no banner, nothing in any log.
///
/// The numbers here are transcribed from firmware
/// `examples/companion_radio/OffbandConfigProtocol.h` on `firmware-base` at
/// `28785ebf` (PR OffbandMesh/meshcore-firmware#2000). The header is the
/// registry. Do not take a sub-code from an Agent Mail message or from this
/// comment: read the header, because taking numbers from mail is what caused
/// the collision.
///
/// Rotation is advertised by `TAG_DISPLAY_ROTATION` in the `0xC5` `0x1C`
/// advert, NOT by caps2 `0x04` INDICATORS and NOT by probing `0x1A` and
/// watching for a refusal. Contract §3 forbids that probing outright:
/// "what is forbidden is discovering support by trying each feature's sub-code
/// and watching for errors." Display mode and the LED keep the INDICATORS bit.
///
/// A board without a display, or without a controllable LED, refuses that
/// half with reason 6; a display that cannot turn refuses rotation with 10.

const int offbandCap2Indicators = 0x04;

const int offbandUiDisplayGet = 0x05;
const int offbandUiDisplaySet = 0x06;
const int offbandUiLedGet = 0x07;
const int offbandUiLedSet = 0x08;
const int offbandUiRotationGet = 0x1A;
const int offbandUiRotationSet = 0x1B;

/// The rotations the radio accepts, in degrees.
const List<int> displayRotations = [0, 180];

bool firmwareSupportsIndicators(int? offbandCaps2) =>
    offbandCaps2 != null && (offbandCaps2 & offbandCap2Indicators) != 0;

/// When the radio's screen is lit. Values are the wire encoding.
enum DisplayMode {
  auto(0, 'Auto', 'On while in use, then off after the screen timeout'),
  alwaysOn(1, 'Always on', 'Never turns off by itself'),
  alwaysOff(2, 'Always off', 'Stays dark');

  const DisplayMode(this.code, this.label, this.description);
  final int code;
  final String label;
  final String description;

  static DisplayMode? fromCode(int code) {
    for (final m in DisplayMode.values) {
      if (m.code == code) return m;
    }
    return null;
  }
}

Uint8List buildDisplayGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiDisplayGet]);

Uint8List buildDisplaySetFrame(DisplayMode mode) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiDisplaySet, mode.code]);

Uint8List buildLedGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiLedGet]);

Uint8List buildLedSetFrame({required bool on}) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiLedSet, on ? 1 : 0]);

Uint8List buildRotationGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiRotationGet]);

Uint8List buildRotationSetFrame(int degrees) {
  if (!displayRotations.contains(degrees)) {
    throw ArgumentError.value(degrees, 'degrees', 'must be 0 or 180');
  }
  return Uint8List.fromList([
    cmdOffbandDeviceUi,
    offbandUiRotationSet,
    degrees,
  ]);
}

/// Parse a display, LED or rotation reply. Null if this is not one, or if it
/// is truncated. The shared 0x7F error is owned by [parseButtonMatrixReply].
IndicatorReply? parseIndicatorReply(Uint8List frame) {
  if (frame.length < 3 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];
  final value = frame[2];
  switch (sub) {
    case offbandUiLedGet || offbandUiLedSet:
      return IndicatorReply(sub: sub, ledOn: value != 0);
    case offbandUiDisplayGet || offbandUiDisplaySet:
      final mode = DisplayMode.fromCode(value);
      if (mode == null) {
        return IndicatorReply(
          sub: sub,
          errorMessage:
              'The radio reported an unknown display mode (${_hex(value)})',
        );
      }
      return IndicatorReply(sub: sub, displayMode: mode);
    case offbandUiRotationGet || offbandUiRotationSet:
      if (!displayRotations.contains(value)) {
        return IndicatorReply(
          sub: sub,
          errorMessage: 'The radio reported an unknown rotation ($value)',
        );
      }
      return IndicatorReply(sub: sub, rotation: value);
  }
  return null;
}

String _hex(int b) => '0x${b.toRadixString(16).padLeft(2, '0')}';

class IndicatorReply {
  const IndicatorReply({
    required this.sub,
    this.displayMode,
    this.ledOn,
    this.rotation,
    this.errorMessage,
  });

  final int sub;
  final DisplayMode? displayMode;
  final bool? ledOn;

  /// Degrees, always one of [displayRotations].
  final int? rotation;
  final String? errorMessage;

  DeviceUiSurface get surface => switch (sub) {
    offbandUiLedGet || offbandUiLedSet => DeviceUiSurface.led,
    offbandUiRotationGet || offbandUiRotationSet => DeviceUiSurface.rotation,
    _ => DeviceUiSurface.display,
  };

  bool get isWrite =>
      sub == offbandUiDisplaySet ||
      sub == offbandUiLedSet ||
      sub == offbandUiRotationSet;
}
