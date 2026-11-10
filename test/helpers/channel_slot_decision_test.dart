// Channel slot allocation (#1021). Adding a channel could overwrite another,
// including Public, losing it from the client and the radio.
//
// Three faults combined: the slot was chosen when the add dialog opened, the
// connector empties its channel list during a sync so any index looked free,
// and the chooser answered "no free slot" with slot 0, which is where Public
// normally lives. These pin the decision so none of them can come back.
//
// #1117: slot 0 is Public's. Firmware #1896 refuses any other channel there,
// even while it is empty, and refuses Public anywhere else (owner 2026-10-28:
// slot 0 "should always remain public").

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/channel_slot_decision.dart';
import 'package:meshcore_open/models/channel.dart';

Channel _ch(int index, {String name = 'ch', String? pskHex}) => Channel(
  index: index,
  name: name,
  psk: Channel.parsePskHex(pskHex ?? '00112233445566778899aabbccddeeff'),
);

Channel _public(int index) => Channel(
  index: index,
  name: 'Public',
  psk: Channel.parsePskHex(Channel.publicChannelPsk),
);

ChannelSlotDecision _other(List<Channel> channels, {int max = 8}) =>
    decideChannelSlot(
      channels: channels,
      maxChannels: max,
      isSyncing: false,
      isPublic: false,
    );

ChannelSlotDecision _forPublic(List<Channel> channels, {int max = 8}) =>
    decideChannelSlot(
      channels: channels,
      maxChannels: max,
      isSyncing: false,
      isPublic: true,
    );

void main() {
  group('decideChannelSlot', () {
    test('takes the lowest free slot', () {
      final d = _other([_public(0), _ch(1), _ch(3)]);
      expect(d.isAllowed, isTrue);
      expect(d.slot, 2);
      expect(d.refusal, isNull);
    });

    test('refuses with full, NEVER slot 0, when every slot is used', () {
      final d = _other([for (var i = 0; i < 8; i++) _ch(i)]);
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
      // so an empty list plus a free-looking slot is exactly the state that
      // overwrote Public.
      for (final isPublic in [false, true]) {
        final d = decideChannelSlot(
          channels: const [],
          maxChannels: 8,
          isSyncing: true,
          isPublic: isPublic,
        );
        expect(d.isAllowed, isFalse);
        expect(d.refusal, ChannelSlotRefusal.syncing);
        expect(d.slot, isNull);
      }
    });

    test('syncing is refused even when a slot genuinely is free', () {
      final d = decideChannelSlot(
        channels: [_public(0)],
        maxChannels: 8,
        isSyncing: true,
        isPublic: false,
      );
      expect(d.refusal, ChannelSlotRefusal.syncing);
    });

    test('syncing takes precedence over full', () {
      final d = decideChannelSlot(
        channels: [for (var i = 0; i < 8; i++) _ch(i)],
        maxChannels: 8,
        isSyncing: true,
        isPublic: false,
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
      final d = _other([_public(0), _ch(1)]);
      expect(
        d.isAllowed,
        isTrue,
        reason: 'a failed sync must not disable adding channels',
      );
      expect(d.slot, 2);
    });

    test('an out-of-range index in the list does not block a free slot', () {
      // Defensive: a stale or odd index must not make the radio look full.
      expect(_other([_ch(99)], max: 4).slot, 1);
    });

    test('a decision is either a slot or a refusal, never both', () {
      final allowed = _other(const [], max: 4);
      final refused = decideChannelSlot(
        channels: const [],
        maxChannels: 4,
        isSyncing: true,
        isPublic: false,
      );
      expect(allowed.slot != null && allowed.refusal == null, isTrue);
      expect(refused.slot == null && refused.refusal != null, isTrue);
    });
  });

  // #1117: firmware #1896 refuses these writes with the same error code as an
  // occupied slot, so the client must never ask for them.
  group('slot 0 is Public\'s', () {
    test('no other channel gets slot 0, even on an empty radio', () {
      final d = _other(const []);
      expect(d.slot, 1, reason: 'firmware refuses a non-Public slot 0 write');
    });

    test('no other channel gets slot 0 when it is the only free slot', () {
      final d = _other([for (var i = 1; i < 8; i++) _ch(i)]);
      expect(d.refusal, ChannelSlotRefusal.full);
    });

    test('a one-slot radio has no room for anything but Public', () {
      expect(_other(const [], max: 1).refusal, ChannelSlotRefusal.full);
      expect(_forPublic(const [], max: 1).slot, 0);
    });

    test('Public goes to slot 0 when it is free', () {
      expect(_forPublic([_ch(1), _ch(2)]).slot, 0);
    });

    test('Public goes to slot 0 even when lower-numbered gaps exist', () {
      expect(_forPublic([_ch(3)]).slot, 0);
    });

    test('Public falls back to a free slot only when slot 0 is taken', () {
      // Older firmware only: a channel other than Public can hold slot 0
      // there, and it accepts Public anywhere.
      expect(_forPublic([_ch(0), _ch(1)]).slot, 2);
    });

    test('a full radio refuses Public too, never slot 0 over a channel', () {
      expect(
        _forPublic([for (var i = 0; i < 8; i++) _ch(i)]).refusal,
        ChannelSlotRefusal.full,
      );
    });
  });

  group('Channel helpers for the slot-0 rule', () {
    test('Public is known by its key', () {
      expect(
        Channel.isPublicKey(Channel.parsePskHex(Channel.publicChannelPsk)),
        isTrue,
      );
      expect(Channel.isPublicKey(_ch(1).psk), isFalse);
    });

    test('a hashtag of "public" means Public, as on the device', () {
      for (final typed in [
        'public',
        'Public',
        'PUBLIC',
        '#public',
        '##public',
        ' #Public ',
        '# public',
      ]) {
        expect(Channel.hashtagMeansPublic(typed), isTrue, reason: typed);
      }
    });

    test('anything else stays a hashtag channel', () {
      for (final typed in ['publics', 'public2', 'pub lic', '#pub', 'publ']) {
        expect(Channel.hashtagMeansPublic(typed), isFalse, reason: typed);
      }
    });
  });

  group('Uint8List psk sanity', () {
    test('the helper builds channels with a real 16 byte psk', () {
      expect(_ch(0).psk, isA<Uint8List>());
      expect(_ch(0).psk.length, 16);
    });
  });
}
