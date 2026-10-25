import 'dart:typed_data';

import 'offband_screen_settings.dart';
import 'offband_tones.dart';

/// Headless-device UI configuration: the button-action matrix (#474) and the
/// device notification scope (#475).
///
/// ⚠ THE COMMAND DOES NOT EXIST ON THE WIRE YET. Firmware confirmed
/// (FuchsiaCreek, 2026-08-01) that nothing currently reads or writes either
/// surface: the capability bit is discoverable, but the scope changes only by
/// triple-pressing the device, and the button matrix is unwritten. Firmware
/// asked for a client-specified shape and is building to the spec below, so
/// this file is the proposal, kept in one place so a landed contract is a
/// constant change rather than a rewrite.
///
/// Until firmware lands it, [MeshCoreConnector.supportsDeviceUiCommand] is
/// false and no frame is ever emitted. The client can see that a radio supports
/// the feature without being able to query it, which is exactly what the UI
/// reports.
///
/// ONE command byte covers both epics, sub-code selects the surface, so #510
/// does not need a second allocation. 0xC5 is the next free code after 0xC0
/// config, 0xC1 GPS, 0xC2 block, 0xC3 FEM LNA, 0xC4 caplog.
///
/// Deliberately NOT folded into `CMD_OFFBAND_CONFIG` 0xC0: that command is
/// observer-only (its backend compiles only under `OFFBAND_OBSERVER` and the
/// client gates it on `WIFI_OBSERVER_SUPPORT`), so extending it would make the
/// feature unreachable on headless trackers, the exact boards it exists for.
///
/// Companion-API only, NEVER on the mesh: it changes only this node's own
/// button handling and buzzer, touching no forwarding, relay, or advert path.
///
///   scope   GET `[0xC5][0x01]`        -> `[0xC5][0x01][scope]`
///           SET `[0xC5][0x02][scope]` -> echo on success
///   matrix  GET `[0xC5][0x03]`
///             -> `[0xC5][0x03][supportedActions][n]([sequence][action]) * n`
///           SET `[0xC5][0x04][sequence][action]` -> echo on success
///   error   `[0xC5][0x7F][reason]`
/// Whether the `0xC5` get/set command exists in shipped firmware.
///
/// TRUE: the client renders the real controls and speaks the canonical `0xC5`
/// contract published in the firmware registry.
///
/// Owner instruction 2026-08-01: the app is where this gets configured. The
/// client is not the thing holding the feature back, so the controls are live
/// and code to the contract as written.
///
/// Until the firmware handler answers, a read shows its loading row and a write
/// is not confirmed, because state only ever follows the device's reply and is
/// never assumed from the request. Nothing is faked and nothing is written
/// locally that the radio has not acknowledged.
const bool deviceUiCommandLanded = true;

const int cmdOffbandDeviceUi = 0xC5;
const int respCodeOffbandDeviceUi = 0xC5;

const int offbandUiScopeGet = 0x01;
const int offbandUiScopeSet = 0x02;
const int offbandUiMatrixGet = 0x03;
const int offbandUiMatrixSet = 0x04;

/// Per-channel tune (#971, meshcore-firmware#1789). Both reply
/// `[0xC5][sub][ch][stored]`, the SET reply re-read after the write.
const int offbandUiChannelTuneGet = 0x0B;
const int offbandUiChannelTuneSet = 0x0C;

/// GPS mode and Power-save interval (#969, meshcore-firmware#1789). Both reply
/// with the same 14-byte state, the SET reply re-read after the write.
const int offbandUiGpsGet = 0x0D;
const int offbandUiGpsSet = 0x0E;
const int _gpsReplyLength = 14;

/// Shared error sub-code. The reply carries a reason byte rather than the
/// generic `[RESP_CODE_ERR][ERR_CODE_ILLEGAL_ARG]` pair, because both epics
/// require the user to be shown *why* an assignment was refused: "this board
/// has no buzzer" and "unknown action" are different answers and a single
/// illegal-arg code cannot express them.
const int offbandUiErr = 0x7F;

/// Why the device refused a write. Unknown values are preserved and surfaced
/// verbatim rather than collapsed into a generic failure, so firmware can add
/// reasons without the client hiding them.
enum ButtonConfigError {
  unsupportedAction(0x01, 'This radio does not support that action'),
  unknownSequence(0x02, 'This radio does not recognise that button sequence'),
  noBuzzer(0x03, 'This radio has no buzzer'),
  noGps(0x04, 'This radio has no GPS'),
  malformed(0x05, 'The radio could not read the request'),
  unsupportedIndicator(0x06, 'This radio has no display or LED to set'),
  slotOffset(
    0x07,
    'The radio stopped accepting this tune partway through. Nothing was '
    'changed. Try saving again.',
  ),
  batteryTooHigh(
    0x08,
    'The reading is higher than a full cell, so it was not used.',
  ),
  batteryNotCharged(
    0x09,
    'Not charged yet. Charge the radio fully, then set 100% again. Nothing '
    'was changed.',
  );

  const ButtonConfigError(this.code, this.message);
  final int code;
  final String message;

  static String describe(int code) {
    for (final e in ButtonConfigError.values) {
      if (e.code == code) return e.message;
    }
    // Never swallow an unrecognised reason: show the raw code so a newer
    // firmware's error is still actionable rather than invisible.
    return 'The radio refused the change (reason 0x'
        '${code.toRadixString(16).padLeft(2, '0')})';
  }
}

/// Which `0xC5` surface a write targeted. The shared error frame
/// `[0xC5][0x7F][reason]` names no sub-code, so the client attributes an error
/// to the write it has outstanding, and each screen shows only its own.
enum DeviceUiSurface {
  buttonMatrix,
  notifyScope,
  gpsMode,
  channelTune,
  eventTone,
  tunePlay,
  tuneSlot,
  screenSettings,
}

/// The refusal reason for a GPS write. Reason 1 means Power save on a build
/// that cannot run it (meshcore-firmware#1789); the rest read as for buttons.
String describeGpsError(int code) => code == 0x01
    ? 'This radio cannot run Power save'
    : ButtonConfigError.describe(code);

/// A button press sequence. Values are the wire encoding.
///
/// Long-press sequences are deliberately absent: firmware reserves long-press
/// under 8 seconds for CLI rescue and 8 seconds or more for power off, and
/// making either reassignable would let a user lock themselves out of a
/// screenless device with no way back.
enum ButtonSequence {
  single(0x00, 'Single press'),
  double(0x01, 'Double press'),
  triple(0x02, 'Triple press'),
  quadruple(0x03, 'Quadruple press');

  const ButtonSequence(this.code, this.label);
  final int code;
  final String label;

  static ButtonSequence? fromCode(int code) {
    for (final s in ButtonSequence.values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// An action assignable to a sequence. The device advertises which of these it
/// actually supports; the client never offers one the radio did not claim.
enum ButtonAction {
  none(0x00, 'Unassigned'),
  sendAdvert(0x01, 'Send advert'),
  toggleGps(0x02, 'Toggle GPS'),
  cycleNotifyScope(0x03, 'Cycle notification scope'),
  batteryBeep(0x04, 'Battery / status beep');

  const ButtonAction(this.code, this.label);
  final int code;
  final String label;

  /// Bit position in the device's supported-actions mask.
  int get mask => code == 0 ? 0 : 1 << (code - 1);

  static ButtonAction? fromCode(int code) {
    for (final a in ButtonAction.values) {
      if (a.code == code) return a;
    }
    return null;
  }
}

/// Device notification scope (#475). Governs whether the DEVICE buzzer sounds.
///
/// Distinct from the app's per-channel [ChannelNotifyMode], which governs
/// whether the PHONE notifies. Same vocabulary deliberately; they are
/// complementary and must never be merged or made to shadow each other.
enum DeviceNotifyScope {
  all(0x00, 'All', 'Beep for any received message'),
  self(0x01, 'Self', 'Beep only for direct messages and @[mentions]'),
  none(0x02, 'None', 'Never beep');

  const DeviceNotifyScope(this.code, this.label, this.description);
  final int code;
  final String label;
  final String description;

  static DeviceNotifyScope? fromCode(int code) {
    for (final s in DeviceNotifyScope.values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// How GPS runs (#969). Values are the wire encoding and firmware's
/// `offband::GpsMode`.
///
/// One control writes this, the way the badge's own GPS screen does through
/// `setGpsMode()`: Off turns GPS off and leaves the remembered mode byte alone,
/// so Off then On returns to Power save rather than to continuous On.
enum GpsMode {
  off(0),
  on(1),
  powerSave(2);

  const GpsMode(this.code);
  final int code;

  static GpsMode? fromCode(int code) {
    for (final m in GpsMode.values) {
      if (m.code == code) return m;
    }
    return null;
  }
}

/// What GPS is doing right now. Display only; firmware pins the bytes.
///
/// Backed off is the state a badge indoors at an event will usually be in, and
/// it reads as a fault unless it is named.
enum GpsActivity {
  off(0),
  on(1),
  searching(2),
  sleeping(3),
  backedOff(4);

  const GpsActivity(this.code);
  final int code;

  static GpsActivity? fromCode(int code) {
    for (final a in GpsActivity.values) {
      if (a.code == code) return a;
    }
    return null;
  }
}

/// The radio's GPS state from a `0xC5` 0x0D or 0x0E reply.
///
/// Every field is what the device holds, never what the client asked for: the
/// SET reply is re-read after the write, so a clamped interval or an Off that
/// kept the remembered mode both show as they really are.
class GpsModeState {
  /// The mode in effect, resolved by firmware from both stored fields.
  final GpsMode mode;

  /// The raw stored mode byte. `0xFF` means never set, which runs as On.
  final int storedMode;

  /// Whether this build can run Power save. Compiled per variant, so this is
  /// the only honest answer to whether the option should be offered.
  final bool powerSaveAvailable;

  /// Null when a newer firmware reports a state this client does not know.
  final GpsActivity? activity;

  /// Sleep between fix attempts in Power save, in seconds. 0 = firmware
  /// default. Firmware raises 1 to 299 to 300.
  final int intervalSeconds;

  /// Seconds until the next fix attempt, or 0.
  final int waitSeconds;

  const GpsModeState({
    required this.mode,
    required this.storedMode,
    required this.powerSaveAvailable,
    required this.activity,
    required this.intervalSeconds,
    required this.waitSeconds,
  });
}

/// A channel's tune choice, as the radio stores it (#971).
///
/// Stored byte 0 means no choice: inherit the global channel tune. Any other
/// value is tune id + 1, and tune id 0 is Silent, a deliberate choice. Those
/// two must never collapse into one "none", because the user cannot tell from
/// the device which one they picked, so they are distinct values here and the
/// byte is never built by hand.
class ChannelTune {
  const ChannelTune.inherit() : stored = 0;

  const ChannelTune._(this.stored);

  /// [tuneId] 0 is Silent. The stored byte is `tuneId + 1`, so 254 is the
  /// highest id that fits.
  factory ChannelTune.tune(int tuneId) {
    if (tuneId < 0 || tuneId > 254) {
      throw ArgumentError.value(tuneId, 'tuneId', 'must be 0 to 254');
    }
    return ChannelTune._(tuneId + 1);
  }

  factory ChannelTune.fromStored(int stored) => ChannelTune._(stored & 0xFF);

  final int stored;

  bool get inherits => stored == 0;
  bool get isSilent => stored == 1;

  /// Null when the channel inherits.
  int? get tuneId => stored == 0 ? null : stored - 1;

  @override
  bool operator ==(Object other) =>
      other is ChannelTune && other.stored == stored;

  @override
  int get hashCode => stored.hashCode;
}

/// One channel's tune, as a `0xC5` 0x0B or 0x0C reply reports it.
class ChannelTuneReply {
  const ChannelTuneReply({required this.channel, required this.tune});
  final int channel;
  final ChannelTune tune;
}

/// The device's current button configuration, as reported by a GET.
class ButtonMatrix {
  /// Sequence to action, only for sequences the device reported.
  final Map<ButtonSequence, ButtonAction> assignments;

  /// Bitmask of actions this specific radio can perform. Derived at runtime by
  /// firmware from compiled-in hardware (no buzzer, no GPS), so it is a
  /// per-unit answer and must never be inferred from model or version.
  final int supportedActions;

  const ButtonMatrix({
    required this.assignments,
    required this.supportedActions,
  });

  bool supports(ButtonAction action) =>
      action == ButtonAction.none || (supportedActions & action.mask) != 0;

  /// Actions this radio will accept, always including "Unassigned" so any
  /// sequence can be cleared.
  List<ButtonAction> get availableActions =>
      ButtonAction.values.where(supports).toList();

  ButtonMatrix withAssignment(ButtonSequence seq, ButtonAction action) =>
      ButtonMatrix(
        assignments: {...assignments, seq: action},
        supportedActions: supportedActions,
      );
}

Uint8List buildButtonMatrixGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiMatrixGet]);

Uint8List buildButtonMatrixSetFrame(
  ButtonSequence sequence,
  ButtonAction action,
) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiMatrixSet,
  sequence.code,
  action.code,
]);

Uint8List buildNotifyScopeGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiScopeGet]);

Uint8List buildNotifyScopeSetFrame(DeviceNotifyScope scope) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiScopeSet, scope.code]);

int _channelByte(int channel) {
  if (channel < 0 || channel > 0xFF) {
    throw ArgumentError.value(channel, 'channel', 'must be 0 to 255');
  }
  return channel;
}

Uint8List buildChannelTuneGetFrame(int channel) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiChannelTuneGet,
  _channelByte(channel),
]);

Uint8List buildChannelTuneSetFrame(int channel, ChannelTune tune) =>
    Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiChannelTuneSet,
      _channelByte(channel),
      tune.stored,
    ]);

Uint8List buildGpsModeGetFrame() =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiGpsGet]);

/// `[0xC5][0x0E][mode][interval_s:4 LE]`. The interval always travels with the
/// mode, so a mode change must resend the current interval to keep it.
Uint8List buildGpsModeSetFrame(GpsMode mode, int intervalSeconds) {
  final frame = Uint8List(7);
  frame[0] = cmdOffbandDeviceUi;
  frame[1] = offbandUiGpsSet;
  frame[2] = mode.code;
  ByteData.sublistView(frame).setUint32(3, intervalSeconds, Endian.little);
  return frame;
}

/// Outcome of a `0xC5` / `0xC6` reply. Exactly one of the payload fields is
/// non-null; [errorMessage] is set when the device refused.
class OffbandUiReply {
  final int command;
  final int sub;
  final ButtonMatrix? matrix;
  final ButtonSequence? setSequence;
  final ButtonAction? setAction;
  final DeviceNotifyScope? scope;
  final GpsModeState? gps;
  final ChannelTuneReply? channelTune;
  final EventToneReply? eventTone;
  final TuneSlotReply? tuneSlot;
  final TuneSlotAccepted? slotAccepted;
  final TuneSlotChunk? slotChunk;
  final TunePlayReply? tunePlay;
  final ScreenSettingsState? screen;
  final String? errorMessage;

  /// The raw reason byte of a `0x7F` error, so a surface can word it for its
  /// own context. Null on every other reply.
  final int? errorCode;

  /// The byte after the reason, when the error carries one: `ERR_SLOT_OFFSET`
  /// sends the offset the radio expects next.
  final int? errorDetail;

  const OffbandUiReply({
    required this.command,
    required this.sub,
    this.matrix,
    this.setSequence,
    this.setAction,
    this.scope,
    this.gps,
    this.channelTune,
    this.eventTone,
    this.tuneSlot,
    this.slotAccepted,
    this.slotChunk,
    this.tunePlay,
    this.screen,
    this.errorMessage,
    this.errorCode,
    this.errorDetail,
  });

  bool get isError => errorMessage != null;
}

/// Parse a `0xC5` button-matrix reply. Null if this is not one.
///
/// Every length check is explicit: a truncated or hostile frame yields null or
/// an error reply, never an out-of-range index.
OffbandUiReply? parseButtonMatrixReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];

  if (sub == offbandUiErr) {
    final code = frame.length >= 3 ? frame[2] : 0x00;
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      errorMessage: ButtonConfigError.describe(code),
      errorCode: code,
      errorDetail: frame.length >= 4 ? frame[3] : null,
    );
  }

  if (sub == offbandUiMatrixGet) {
    if (frame.length < 4) return null;
    final supported = frame[2];
    final count = frame[3];
    final assignments = <ButtonSequence, ButtonAction>{};
    for (var i = 0; i < count; i++) {
      final base = 4 + (i * 2);
      // Stop at the real end of the frame rather than trusting the count byte.
      if (base + 1 >= frame.length) break;
      final seq = ButtonSequence.fromCode(frame[base]);
      final action = ButtonAction.fromCode(frame[base + 1]);
      // An unknown sequence or action from newer firmware is skipped rather
      // than guessed at; the rows the client does understand still render.
      if (seq != null && action != null) assignments[seq] = action;
    }
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      matrix: ButtonMatrix(
        assignments: assignments,
        supportedActions: supported,
      ),
    );
  }

  if (sub == offbandUiMatrixSet) {
    if (frame.length < 4) return null;
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      setSequence: ButtonSequence.fromCode(frame[2]),
      setAction: ButtonAction.fromCode(frame[3]),
    );
  }

  return null;
}

/// Parse a `0xC6` notification-scope reply. Null if this is not one.
OffbandUiReply? parseNotifyScopeReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];

  // The shared 0x7F error sub-code is owned by parseButtonMatrixReply, which
  // the dispatcher tries first, so it is deliberately not handled twice here.
  if (sub != offbandUiScopeGet && sub != offbandUiScopeSet) return null;
  if (frame.length < 3) return null;
  final scope = DeviceNotifyScope.fromCode(frame[2]);
  if (scope == null) {
    // A scope the client does not know is an error the user can see, not a
    // silent fallback to some default that would misreport the device.
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      errorMessage:
          'The radio reported an unknown notification scope '
          '(0x${frame[2].toRadixString(16).padLeft(2, '0')})',
    );
  }
  return OffbandUiReply(
    command: respCodeOffbandDeviceUi,
    sub: sub,
    scope: scope,
  );
}

/// Parse a `0xC5` channel-tune reply (0x0B or 0x0C). Null if this is not one,
/// or if it is truncated. Any stored byte is a valid value; which ones the
/// badge's picker offers is the firmware's to enforce, and it refuses the rest.
OffbandUiReply? parseChannelTuneReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];
  if (sub != offbandUiChannelTuneGet && sub != offbandUiChannelTuneSet) {
    return null;
  }
  if (frame.length < 4) return null;
  return OffbandUiReply(
    command: respCodeOffbandDeviceUi,
    sub: sub,
    channelTune: ChannelTuneReply(
      channel: frame[2],
      tune: ChannelTune.fromStored(frame[3]),
    ),
  );
}

/// Parse a `0xC5` GPS-mode reply (0x0D or 0x0E). Null if this is not one, or
/// if it is shorter than the 14 bytes the contract fixes: a partial state is
/// never shown as if it were the device's.
///
/// The shared 0x7F error is owned by [parseButtonMatrixReply], as for scope.
OffbandUiReply? parseGpsModeReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];
  if (sub != offbandUiGpsGet && sub != offbandUiGpsSet) return null;
  if (frame.length < _gpsReplyLength) return null;

  final mode = GpsMode.fromCode(frame[2]);
  if (mode == null) {
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      errorMessage:
          'The radio reported an unknown GPS mode '
          '(0x${frame[2].toRadixString(16).padLeft(2, '0')})',
    );
  }
  final data = ByteData.sublistView(frame);
  return OffbandUiReply(
    command: respCodeOffbandDeviceUi,
    sub: sub,
    gps: GpsModeState(
      mode: mode,
      storedMode: frame[3],
      powerSaveAvailable: frame[4] != 0,
      activity: GpsActivity.fromCode(frame[5]),
      intervalSeconds: data.getUint32(6, Endian.little),
      waitSeconds: data.getUint32(10, Endian.little),
    ),
  );
}
