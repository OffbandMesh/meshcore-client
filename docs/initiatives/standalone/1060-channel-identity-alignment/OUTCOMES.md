# Channel identity alignment: erased slots and slot-keyed notify (#1060)

Agent: CalmBay. Branch `feat/1068-radio-channel-notify`. No push, no PR.

## 1. Who owns the "key by identity, not slot" work

**Feature #1061, agent TurquoiseBridge (session 82d77b2f).** The identity key is
the channel's **PSK hex**, not a pubkey; channels have no pubkey, and the PSK is
what both history and settings already hang off.

| Issue | What | State |
|---|---|---|
| #1060 | the bug: slot map diverges after wipe + re-import, wrong-channel notifications | open |
| #1061 | feature: channel state follows channel identity | open |
| #1062 | fail-closed sync, ingress barrier, slot identity diff | landed |
| #1063 | message history keyed by channel identity | landed |
| #1064 | integration testing + #1060 bug validation | **open** |

The pattern itself is older than #1061: `feat(#260)` (2026-07-17) introduced
PSK-keyed notify storage, `fix(#848)` scoped it per radio and killed the index
fallback, and `#194` keyed message history the same way.

`test/connector/channel_slot_resync_integration_test.dart` already encodes the
exact field case, down to `#wardriving` set to OFF.

## 2. What was still slot-keyed

#544 (epics #1068-#1071, this branch) added the RADIO-side per-channel notify
after #1061 landed, and keyed it by **slot index**:

```dart
final Map<int, RadioChannelNotify> _channelNotifyModes = {};
```

That re-opened the exact class of defect #1061 was built to close, on the one
surface where the user notices it fastest: the buzzer. The slot-identity-change
handler cleared `_channelMessages[slot]` but not `_channelNotifyModes[slot]`,
so after a slot shift the new occupant inherited the old one's mode.

Reproduced by planting the slot-keyed map back and running the new A5 test:

```
Expected: null
  Actual: RadioChannelNotify:<RadioChannelNotify.off>
```

A channel silenced on the radio handing its Off to whatever took its slot, and
losing its own. That is the chirping.

### Fixed

- `_channelNotifyModes` is keyed by **PSK hex**. The wire stays slot-addressed;
  the slot is resolved to an identity at the wire edge and nowhere else.
- A reply whose slot does not resolve to a confirmed channel is **dropped**,
  not stored against a slot number.
- `setChannelNotify` takes a `Channel` and resolves its **current** slot at
  send time, so a `Channel` a widget captured before a re-sync cannot address a
  stale slot. Unresolvable means a visible refusal, no frame.

## 3. The erased-slot defect

Erased flash reads back as `0xFF`. `Channel.isEmpty` tests for `0x00`, so an
erased record is not empty: it was adopted as a channel, rendered with U+FFFD
replacement characters, and then **saved over the client's own good list**.

That is one missing validation gate, not two defects. The rendering and the
overwrite are the same hole seen twice.

### Fixed

- `Channel.isErased` / `isUnusable`: an all-`0xFF` record, or a name that did
  not decode, is never adopted.
- A sync that sees an erased slot **keeps the cached list** instead of
  overwriting it, reusing the fail-closed branch #1062 already had for holes.
- `restoreChannelsToRadio()` writes the cached channels back to their own
  slots, with their PSKs, so history and settings line up again. Surfaced as an
  undismissable banner with a confirmed **Restore to radio** action.

Probe: forcing `isErased => false` turns 5 of the new tests red, including the
cache overwrite.

## 4. Recovery for the list already lost

Not built, flagged for a decision. Message history keys are
`channel_messages_<devicePrefix>psk_<pskHex>`, so **the PSKs of the lost
channels still exist in the message store** even though the channel list was
overwritten. A recovery pass could enumerate those keys and rebuild the list.
Names would need retyping; the PSK is the part that matters.

## 5. State

`flutter analyze` clean. **1885 tests pass, 1 skipped.** New strings are
English-only with `untranslated.json` regenerated.

Not pushed, no PR: the owner's gate is a hardware test first.
