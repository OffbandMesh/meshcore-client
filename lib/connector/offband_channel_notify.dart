import 'dart:typed_data';

import 'offband_device_ui.dart';

/// Per-channel notification mode stored on the RADIO, over `0xC5` 0x18 / 0x19
/// (#544, meshcore-firmware#606).
///
/// This governs the RADIO's buzzer and nothing else. It is deliberately
/// independent of the app's own per-channel `ChannelNotifyMode`, which governs
/// whether the PHONE notifies: two settings, two outputs, no bridging between
/// them (owner, 2026-11-03: "they are separate controls and separate
/// notifications... they are independent settings"). Never resolve one from
/// the other, and never offer an "inherit the app setting" value here.
///
/// Firmware is the authority and there is no firmware inherit concept: the
/// owner's ruling was "Inherit is on the client side, not on the firmware
/// side. How would firmware inherit from firmware?". [unset] is simply the
/// absence of a per-channel choice, and the radio's own device-wide scope
/// answers for that channel instead.
const int offbandUiChannelNotifyGet = 0x18;
const int offbandUiChannelNotifySet = 0x19;

/// A channel's radio notify mode, as the radio stores it.
///
/// The byte is **1-based** and 0 means "no choice made", because the value
/// lives in a field that reads zero on every existing record and every fresh
/// channel. If 0 meant a real mode, every untouched channel in the field would
/// silently adopt it. The shipped `ChannelTune` byte uses the same convention
/// for the same reason, so the two are consistent on the wire.
///
/// `[verified 2026-11-04 against firmware src/helpers/ChannelNotify.h on
/// epic/606-channel-notify: kChanNotifyUnset = 0, kChanNotifyAll = 1,
/// kChanNotifyMentions = 2, kChanNotifyOff = 3, kChanNotifyCount = 4.]`
/// The contract calls these All / Self / None plus "follow the device
/// setting"; that is the same encoding in different words, with "Self" being
/// [mentions] and "follow" being [unset].
///
/// Firmware validates a SET with `stored < kChanNotifyCount`, i.e. `mode < 4`
/// and nothing else. That is why a rotation SET on `0x18`/`0x19` was silent
/// corruption rather than a refused command: every rotation value in 0 to 3
/// passes as a valid notify mode and writes to the channel at that slot. See
/// `offband_indicators.dart`, which now uses `0x1A`/`0x1B`.
enum RadioChannelNotify {
  /// No per-channel choice: the radio's device-wide scope answers instead.
  unset(0x00),

  /// Beep for any message on this channel.
  all(0x01),

  /// Beep only when the message names us, by the `@[name]` rule.
  mentions(0x02),

  /// Never beep for this channel.
  off(0x03);

  const RadioChannelNotify(this.stored);

  /// The wire byte. Never built by hand.
  final int stored;

  static RadioChannelNotify? fromStored(int stored) {
    for (final m in RadioChannelNotify.values) {
      if (m.stored == stored) return m;
    }
    return null;
  }
}

/// One channel's radio notify mode, as a `0xC5` 0x18 or 0x19 reply reports it.
class RadioChannelNotifyReply {
  const RadioChannelNotifyReply({required this.channel, required this.mode});
  final int channel;
  final RadioChannelNotify mode;
}

int _channelByte(int channel) {
  if (channel < 0 || channel > 0xFF) {
    throw ArgumentError.value(channel, 'channel', 'must be 0 to 255');
  }
  return channel;
}

Uint8List buildChannelNotifyGetFrame(int channel) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiChannelNotifyGet,
  _channelByte(channel),
]);

Uint8List buildChannelNotifySetFrame(int channel, RadioChannelNotify mode) =>
    Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiChannelNotifySet,
      _channelByte(channel),
      mode.stored,
    ]);

/// Parse a `0xC5` channel-notify reply (0x18 or 0x19). Null when this is not
/// one, when it is short, or when the mode byte is not a value we know: an
/// unrecognized mode is dropped rather than guessed at, so a firmware that
/// grows a fourth mode cannot have it read as one of ours.
RadioChannelNotifyReply? parseChannelNotifyReply(List<int> frame) {
  if (frame.length < 4) return null;
  if (frame[0] != respCodeOffbandDeviceUi) return null;
  if (frame[1] != offbandUiChannelNotifyGet &&
      frame[1] != offbandUiChannelNotifySet) {
    return null;
  }
  final mode = RadioChannelNotify.fromStored(frame[3]);
  if (mode == null) return null;
  return RadioChannelNotifyReply(channel: frame[2], mode: mode);
}
