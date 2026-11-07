// #1117: Restore to radio places by identity. The plan is pure, so its rules
// are pinned here directly; channel_erased_slot_test drives it through the
// connector against a radio that answers.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/channel_restore_plan.dart';
import 'package:meshcore_open/models/channel.dart';

Channel _ch(int index, String name, int fill) => Channel(
  index: index,
  name: name,
  psk: Uint8List.fromList(List<int>.filled(16, fill)),
);

final _public = Channel(
  index: 3,
  name: 'Public',
  psk: Channel.parsePskHex(Channel.publicChannelPsk),
);

ChannelRestorePlan _plan(
  List<Channel> cached, {
  List<Channel> live = const [],
  Set<int> erased = const {},
  int max = 8,
}) => planChannelRestore(
  cached: cached,
  live: live,
  erasedSlots: erased,
  maxChannels: max,
);

Map<String, int> _slots(ChannelRestorePlan p) => {
  for (final s in p.steps) s.channel.name: s.slot,
};

void main() {
  test('Public goes to slot 0, wherever the cache remembered it', () {
    expect(_slots(_plan([_public])), {'Public': 0});
  });

  test('Public is placed first, so nothing else can take slot 0', () {
    final p = _plan([_ch(0, 'old zero', 1), _public]);
    expect(_slots(p), {'Public': 0, 'old zero': 1});
  });

  test('with a live channel in slot 0, Public takes a free slot instead', () {
    // Older firmware only: nothing is written over the live channel.
    final p = _plan([_public], live: [_ch(0, 'live', 9)]);
    expect(_slots(p)['Public'], isNot(0));
  });

  test('a channel keeps its remembered slot when that slot is free', () {
    expect(_slots(_plan([_ch(4, 'four', 4)])), {'four': 4});
  });

  test('a channel never overwrites a live one; it moves', () {
    final p = _plan([_ch(1, 'cached', 1)], live: [_ch(1, 'live', 2)]);
    expect(_slots(p)['cached'], 2);
  });

  test('a channel the radio still has, in any slot, is left out', () {
    final p = _plan([_ch(1, 'same', 1)], live: [_ch(5, 'same', 1)]);
    expect(p.steps, isEmpty);
    expect(p.noRoom, isEmpty);
  });

  test('only erased slots are cleared first', () {
    final p = _plan(
      [_ch(1, 'erased slot', 1), _ch(2, 'empty slot', 2)],
      erased: {1},
    );
    final clear = {for (final s in p.steps) s.channel.name: s.clearFirst};
    expect(clear, {'erased slot': true, 'empty slot': false});
  });

  test('two remembered at one slot: one keeps it, one moves', () {
    final p = _plan([_ch(1, 'first', 1), _ch(1, 'second', 2)]);
    final slots = _slots(p);
    expect(slots.values.toSet(), hasLength(2), reason: 'never one slot twice');
    expect(slots['first'], 1);
  });

  test('the same key cached twice is written once', () {
    expect(_plan([_ch(1, 'a', 1), _ch(2, 'a again', 1)]).steps, hasLength(1));
  });

  test('erased and empty cached entries are never written', () {
    final erased = Channel(
      index: 2,
      name: 'x',
      psk: Uint8List.fromList(List<int>.filled(16, 0xFF)),
    );
    final empty = Channel(index: 3, name: '', psk: Uint8List(16));
    expect(_plan([erased, empty]).steps, isEmpty);
  });

  test('with no room left, the rest are reported, not dropped', () {
    final p = _plan(
      [_ch(1, 'a', 1), _ch(2, 'b', 2)],
      live: [_ch(1, 'l1', 8), _ch(2, 'l2', 9)],
      max: 3,
    );
    expect(p.steps, isEmpty, reason: 'slot 0 is Public\'s, 1 and 2 are live');
    expect(p.noRoom.map((c) => c.name), ['a', 'b']);
  });
}
