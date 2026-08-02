import 'dart:typed_data';

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
  malformed(0x05, 'The radio could not read the request');

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

/// Outcome of a `0xC5` / `0xC6` reply. Exactly one of the payload fields is
/// non-null; [errorMessage] is set when the device refused.
class OffbandUiReply {
  final int command;
  final int sub;
  final ButtonMatrix? matrix;
  final ButtonSequence? setSequence;
  final ButtonAction? setAction;
  final DeviceNotifyScope? scope;
  final String? errorMessage;

  const OffbandUiReply({
    required this.command,
    required this.sub,
    this.matrix,
    this.setSequence,
    this.setAction,
    this.scope,
    this.errorMessage,
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
    return OffbandUiReply(
      command: respCodeOffbandDeviceUi,
      sub: sub,
      errorMessage: ButtonConfigError.describe(
        frame.length >= 3 ? frame[2] : 0x00,
      ),
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
