import 'dart:typed_data';

import 'offband_device_ui.dart';

/// The radio's tune system over `0xC5` (#970, #971, #986): the built-in tune
/// table, the eight custom RTTTL slots, the six event tones and preview.
///
/// Gated on caps byte 2 `0x10` TUNES (meshcore-firmware `3e788e2a`). The
/// contract lives in firmware's `OffbandConfigProtocol.h`; the tables and the
/// validator below are ports of `Tunes.h` and `TuneSlots.h` at that commit.

const int offbandUiSlotGet = 0x09;
const int offbandUiSlotSet = 0x0A;
const int offbandUiEventToneGet = 0x0F;
const int offbandUiEventToneSet = 0x10;
const int offbandUiTunePlay = 0x11;
const int offbandUiSlotRead = 0x12;

/// The built-in tunes, by id. Firmware's table is append-only, so this copy
/// can only fall behind, never misname an id. A null name is a tune firmware
/// keeps out of its own picker (id 7, Trigger), so it is never offered here.
const List<String?> builtinTuneNames = [
  'Silent',
  'Chime',
  'Kerplop',
  'Tick',
  'Bloop',
  'Drop',
  'Knock',
  null,
];

const int tuneSilent = 0;
const int builtinTuneCount = 8;
const int tuneSlotCount = 8;
const int firstSlotTuneId = builtinTuneCount;

/// The longest RTTTL a slot holds (`kMaxRtttl`) and the longest name a slot
/// shows (`kMaxSlotName`).
const int maxSlotRtttl = 240;
const int maxSlotName = 12;

bool isSlotTuneId(int id) =>
    id >= firstSlotTuneId && id < firstSlotTuneId + tuneSlotCount;

int slotTuneId(int slot) => firstSlotTuneId + slot;

/// Built-in ids the badge's picker lists, in its order.
List<int> get listedBuiltinTuneIds => [
  for (var id = 0; id < builtinTuneNames.length; id++)
    if (builtinTuneNames[id] != null) id,
];

/// One of the six events the badge's Tones screen sets. Values are firmware's
/// `offband::ToneEvent`, and the labels are the badge's own (`kToneEventRows`).
enum ToneEvent {
  dm(0, 'DM'),
  channel(1, 'Channel'),
  room(2, 'Room'),
  newContact(3, 'New contact'),
  ack(4, 'Ack'),
  sent(5, 'Sent');

  const ToneEvent(this.code, this.label);
  final int code;
  final String label;

  static ToneEvent? fromCode(int code) {
    for (final e in ToneEvent.values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

/// Stored byte meaning "nothing chosen": the board's compiled default plays.
const int tuneUnset = 0xFF;

/// An event's tune as the radio reports it. [effective] is what plays.
class EventToneState {
  const EventToneState({required this.stored, required this.effective});
  final int stored;
  final int effective;

  bool get isRadioDefault => stored == tuneUnset;
}

class EventToneReply {
  const EventToneReply({required this.event, required this.state});
  final ToneEvent event;
  final EventToneState state;
}

/// What a custom slot holds, from `SLOT_GET`: its length and derived name,
/// never the tune itself. Length 0 is an empty slot.
class TuneSlotInfo {
  const TuneSlotInfo({required this.length, required this.name});
  final int length;
  final String name;

  bool get isEmpty => length == 0;
}

class TuneSlotReply {
  const TuneSlotReply({required this.slot, required this.info});
  final int slot;
  final TuneSlotInfo info;
}

/// `SLOT_SET` progress: how many bytes the radio holds for the push in flight.
class TuneSlotAccepted {
  const TuneSlotAccepted({required this.slot, required this.accepted});
  final int slot;
  final int accepted;
}

/// One `SLOT_READ` chunk.
class TuneSlotChunk {
  const TuneSlotChunk({
    required this.slot,
    required this.offset,
    required this.more,
    required this.bytes,
  });
  final int slot;
  final int offset;
  final bool more;
  final Uint8List bytes;
}

/// Why a preview did or did not sound (`offband::TonePlay`).
enum TunePlayResult {
  played(0),
  busy(1),
  soundOff(2);

  const TunePlayResult(this.code);
  final int code;

  static TunePlayResult? fromCode(int code) {
    for (final r in TunePlayResult.values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

class TunePlayReply {
  const TunePlayReply({required this.tuneId, required this.result});
  final int tuneId;

  /// Null when a newer firmware reports a result this client does not know.
  final TunePlayResult? result;
}

/// What the client knows of a radio's tunes, for naming an id.
///
/// [slots] holds the `SLOT_GET` replies read so far, by slot index.
String? tuneLabel(int id, Map<int, TuneSlotInfo> slots) {
  if (id >= 0 && id < builtinTuneNames.length) return builtinTuneNames[id];
  if (isSlotTuneId(id)) {
    final info = slots[id - firstSlotTuneId];
    if (info == null || info.isEmpty) return null;
    return info.name.isEmpty ? 'Slot ${id - firstSlotTuneId + 1}' : info.name;
  }
  return null;
}

/// The ids a picker may offer: firmware's rule, a named built-in or a filled
/// slot. Firmware refuses everything else, so nothing else is shown.
List<int> offeredTuneIds(Map<int, TuneSlotInfo> slots) => [
  ...listedBuiltinTuneIds,
  for (var s = 0; s < tuneSlotCount; s++)
    if (slots[s] != null && !slots[s]!.isEmpty) slotTuneId(s),
];

Uint8List buildEventToneGetFrame(ToneEvent event) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiEventToneGet, event.code]);

Uint8List buildEventToneSetFrame(ToneEvent event, int tuneId) =>
    Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiEventToneSet,
      event.code,
      _byte(tuneId, 'tuneId'),
    ]);

Uint8List buildTunePlayFrame(int tuneId) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiTunePlay,
  _byte(tuneId, 'tuneId'),
]);

Uint8List buildSlotGetFrame(int slot) =>
    Uint8List.fromList([cmdOffbandDeviceUi, offbandUiSlotGet, _slotByte(slot)]);

Uint8List buildSlotReadFrame(int slot, int offset) => Uint8List.fromList([
  cmdOffbandDeviceUi,
  offbandUiSlotRead,
  _slotByte(slot),
  _byte(offset, 'offset'),
]);

/// `[0xC5][0x0A][slot][offset][more][bytes...]`. An empty final chunk at
/// offset 0 clears the slot.
Uint8List buildSlotSetFrame(int slot, int offset, bool more, List<int> bytes) =>
    Uint8List.fromList([
      cmdOffbandDeviceUi,
      offbandUiSlotSet,
      _slotByte(slot),
      _byte(offset, 'offset'),
      more ? 1 : 0,
      ...bytes,
    ]);

int _slotByte(int slot) {
  if (slot < 0 || slot >= tuneSlotCount) {
    throw ArgumentError.value(
      slot,
      'slot',
      'must be 0 to ${tuneSlotCount - 1}',
    );
  }
  return slot;
}

int _byte(int value, String name) {
  if (value < 0 || value > 0xFF) {
    throw ArgumentError.value(value, name, 'must be 0 to 255');
  }
  return value;
}

/// Parse a tune reply (0x09, 0x0A, 0x0F, 0x10, 0x11, 0x12). Null if this is
/// not one, or if it is truncated. The shared 0x7F error is owned by
/// [parseButtonMatrixReply].
OffbandUiReply? parseTuneReply(Uint8List frame) {
  if (frame.length < 2 || frame[0] != respCodeOffbandDeviceUi) return null;
  final sub = frame[1];
  OffbandUiReply reply({
    EventToneReply? eventTone,
    TuneSlotReply? slot,
    TuneSlotAccepted? accepted,
    TuneSlotChunk? chunk,
    TunePlayReply? play,
  }) => OffbandUiReply(
    command: respCodeOffbandDeviceUi,
    sub: sub,
    eventTone: eventTone,
    tuneSlot: slot,
    slotAccepted: accepted,
    slotChunk: chunk,
    tunePlay: play,
  );

  switch (sub) {
    case offbandUiEventToneGet:
    case offbandUiEventToneSet:
      if (frame.length < 5) return null;
      final event = ToneEvent.fromCode(frame[2]);
      if (event == null) {
        return OffbandUiReply(
          command: respCodeOffbandDeviceUi,
          sub: sub,
          errorMessage:
              'The radio reported an unknown tone event (${frame[2]})',
        );
      }
      return reply(
        eventTone: EventToneReply(
          event: event,
          state: EventToneState(stored: frame[3], effective: frame[4]),
        ),
      );
    case offbandUiSlotGet:
      if (frame.length < 4) return null;
      // The name is the rest of the frame, at most what the transport carried.
      final name = String.fromCharCodes(frame.sublist(4));
      return reply(
        slot: TuneSlotReply(
          slot: frame[2],
          info: TuneSlotInfo(length: frame[3], name: name),
        ),
      );
    case offbandUiSlotSet:
      if (frame.length < 4) return null;
      return reply(
        accepted: TuneSlotAccepted(slot: frame[2], accepted: frame[3]),
      );
    case offbandUiSlotRead:
      if (frame.length < 5) return null;
      return reply(
        chunk: TuneSlotChunk(
          slot: frame[2],
          offset: frame[3],
          more: frame[4] != 0,
          bytes: Uint8List.fromList(frame.sublist(5)),
        ),
      );
    case offbandUiTunePlay:
      if (frame.length < 4) return null;
      return reply(
        play: TunePlayReply(
          tuneId: frame[2],
          result: TunePlayResult.fromCode(frame[3]),
        ),
      );
  }
  return null;
}

/// Why an RTTTL string is not safe to play, as firmware's `rtttlProblem()`
/// judges it. The same rule runs on the badge's editor and on every pushed
/// tune, so the app checks with it before sending: the radio can only answer
/// "malformed", and this says why.
enum RtttlProblem {
  ok('OK'),
  empty('Empty'),
  noName('Needs a name'),
  missingColon('Needs name:notes'),
  badDefault('Bad d=, o= or b='),
  zeroTempo('b= must be 1 or more'),
  noNotes('No notes'),
  ambiguousNote('Add d=, o= or b= first'),
  strayColon('Bad name or d=/o=/b=');

  const RtttlProblem(this.text);

  /// Firmware's own words (`rtttlProblemText`), so the app and the badge
  /// describe the same problem the same way.
  final String text;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isDefaultsSep(int c) => c == 0x2C || c == 0x3A;

const int _colon = 0x3A;

/// Port of firmware `rtttlProblem()` (`Tunes.h`, `3e788e2a`), step for step.
RtttlProblem rtttlProblem(String rtttl) {
  final s = rtttl.codeUnits;
  if (s.isEmpty) return RtttlProblem.empty;
  int at(int i) => i < s.length ? s[i] : 0;

  var p = 0;
  while (at(p) != 0 && at(p) != _colon) {
    p++;
  }
  if (at(p) == 0) return RtttlProblem.missingColon;
  if (p == 0) return RtttlProblem.noName;
  p++;

  var sawDefault = false;

  if (at(p) == 0x64 && at(p + 1) == 0x3D) {
    p += 2;
    var digits = 0;
    while (_isDigit(at(p))) {
      p++;
      digits++;
    }
    if (digits == 0 || digits > 4) return RtttlProblem.badDefault;
    if (!_isDefaultsSep(at(p))) return RtttlProblem.badDefault;
    p++;
    sawDefault = true;
  }

  if (at(p) == 0x6F && at(p + 1) == 0x3D) {
    if (!_isDigit(at(p + 2))) return RtttlProblem.badDefault;
    if (!_isDefaultsSep(at(p + 3))) return RtttlProblem.badDefault;
    p += 4;
    sawDefault = true;
  }

  if (at(p) == 0x62 && at(p + 1) == 0x3D) {
    p += 2;
    var digits = 0;
    var bpm = 0;
    while (_isDigit(at(p))) {
      if (digits < 5) bpm = bpm * 10 + (at(p) - 0x30);
      p++;
      digits++;
    }
    if (digits == 0) return RtttlProblem.zeroTempo;
    if (digits > 4) return RtttlProblem.badDefault;
    if (bpm == 0) return RtttlProblem.zeroTempo;
    if (!_isDefaultsSep(at(p))) return RtttlProblem.badDefault;
    p++;
    sawDefault = true;
  }

  if (at(p) == 0) return RtttlProblem.noNotes;

  final c = at(p);
  if (!sawDefault && (c == 0x64 || c == 0x6F || c == 0x62)) {
    return RtttlProblem.ambiguousNote;
  }

  for (var q = p; q < s.length; q++) {
    if (s[q] == _colon) return RtttlProblem.strayColon;
  }
  return RtttlProblem.ok;
}

/// Port of firmware `deriveSlotName()`: the text before the first colon,
/// trimmed and cut to [maxSlotName]. Empty when there is no usable name.
String deriveSlotName(String rtttl) {
  final colon = rtttl.indexOf(':');
  if (colon < 0) return '';
  var name = rtttl
      .substring(0, colon)
      .replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');
  if (name.length > maxSlotName) name = name.substring(0, maxSlotName);
  return name;
}
