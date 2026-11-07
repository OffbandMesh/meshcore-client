// Channel slot allocation (#1021). Adding a channel could overwrite another,
// including Public, losing it from the client and the radio.
//
// Three faults combined: the slot was chosen when the add dialog opened, the
// connector empties its channel list during a sync so any index looked free,
// and the chooser answered "no free slot" with slot 0, which is where Public
// normally lives. These pin the decision so none of them can come back.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/channel_slot_decision.dart';
import 'package:meshcore_open/models/channel.dart';

Channel _ch(int index, {String name = 'ch', String? pskHex}) => Channel(
  index: index,
  name: name,
  psk: Channel.parsePskHex(pskHex ?? '00112233445566778899aabbccddeeff'),
);

void main() {
  group('decideChannelSlot', () {
    test('takes the lowest free slot', () {
      final d = decideChannelSlot(
        channels: [_ch(0), _ch(1), _ch(3)],
        maxChannels: 8,
        isSyncing: false,
      );
      expect(d.isAllowed, isTrue);
      expect(d.slot, 2);
      expect(d.refusal, isNull);
    });

    test('takes slot 0 when the radio is empty', () {
      final d = decideChannelSlot(
        channels: const [],
        maxChannels: 8,
        isSyncing: false,
      );
      expect(d.slot, 0);
    });

    test('refuses with full, NEVER slot 0, when every slot is used', () {
      final d = decideChannelSlot(
        channels: [for (var i = 0; i < 8; i++) _ch(i)],
        maxChannels: 8,
        isSyncing: false,
      );
      expect(d.isAllowed, isFalse);
      expect(d.refusal, ChannelSlotRefusal.full);
      expect(
        d.slot,
        isNull,
        reason: 'the old return 0 fallback is what destroyed Public',
      );
    });

    test('refuses while syncing, even though every slot looks free', () {
      // This is the reported bug. Mid-sync the connector has emptied its list,
      // so an empty list plus a free-looking slot 0 is exactly the state that
      // overwrote Public.
      final d = decideChannelSlot(
        channels: const [],
        maxChannels: 8,
        isSyncing: true,
      );
      expect(d.isAllowed, isFalse);
      expect(d.refusal, ChannelSlotRefusal.syncing);
      expect(d.slot, isNull);
    });

    test('syncing is refused even when a slot genuinely is free', () {
      final d = decideChannelSlot(
        channels: [_ch(0)],
        maxChannels: 8,
        isSyncing: true,
      );
      expect(d.refusal, ChannelSlotRefusal.syncing);
    });

    test('syncing takes precedence over full', () {
      final d = decideChannelSlot(
        channels: [for (var i = 0; i < 8; i++) _ch(i)],
        maxChannels: 8,
        isSyncing: true,
      );
      expect(
        d.refusal,
        ChannelSlotRefusal.syncing,
        reason: 'a list being rewritten cannot be trusted to say it is full',
      );
    });

    // The regression test for the gate I nearly got wrong. After a FAILED sync
    // the connector leaves hasLoadedChannels false but restores the cached
    // list into use. Gating on that flag would refuse forever on a flaky link,
    // so the decision takes isSyncing only, and a restored list allocates
    // normally.
    test('allocates normally after a failed sync, from the restored list', () {
      final d = decideChannelSlot(
        channels: [_ch(0), _ch(1)],
        maxChannels: 8,
        isSyncing: false,
      );
      expect(
        d.isAllowed,
        isTrue,
        reason: 'a failed sync must not disable adding channels',
      );
      expect(d.slot, 2);
    });

    test('a single-slot radio can be filled and then refuses', () {
      expect(
        decideChannelSlot(
          channels: const [],
          maxChannels: 1,
          isSyncing: false,
        ).slot,
        0,
      );
      expect(
        decideChannelSlot(
          channels: [_ch(0)],
          maxChannels: 1,
          isSyncing: false,
        ).refusal,
        ChannelSlotRefusal.full,
      );
    });

    test('an out-of-range index in the list does not block a free slot', () {
      // Defensive: a stale or odd index must not make the radio look full.
      final d = decideChannelSlot(
        channels: [_ch(99)],
        maxChannels: 4,
        isSyncing: false,
      );
      expect(d.slot, 0);
    });

    test('Public holds no claim on slot 0, since it is identified by PSK', () {
      // `Channel.isPublicChannel` compares the PSK, not the index, so Public
      // can live anywhere and nothing may assume slot 0 belongs to it.
      final public = Channel(
        index: 3,
        name: 'Public',
        psk: Channel.parsePskHex(Channel.publicChannelPsk),
      );
      expect(public.isPublicChannel, isTrue);
      final d = decideChannelSlot(
        channels: [public],
        maxChannels: 8,
        isSyncing: false,
      );
      expect(d.slot, 0, reason: 'slot 0 is free here and may be used');
    });

    test('a decision is either a slot or a refusal, never both', () {
      final allowed = decideChannelSlot(
        channels: const [],
        maxChannels: 4,
        isSyncing: false,
      );
      final refused = decideChannelSlot(
        channels: const [],
        maxChannels: 4,
        isSyncing: true,
      );
      expect(allowed.slot != null && allowed.refusal == null, isTrue);
      expect(refused.slot == null && refused.refusal != null, isTrue);
    });
  });

  group('Uint8List psk sanity', () {
    test('the helper builds channels with a real 16 byte psk', () {
      expect(_ch(0).psk, isA<Uint8List>());
      expect(_ch(0).psk.length, 16);
    });
  });
}
