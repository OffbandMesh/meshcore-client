# Feature #1061 channel slot resync truth: OUTCOMES

Status: BUILT and machine-verified; PRs opened on the owner's word (decision below), validation moves to live testing after merge. Branch stack: `feat/1062-channel-sync-truth` (Epic A) ← `feat/1063-message-state-hardening` (Epics B + C), rebased onto dev `180c01e6`.

## What was built
| Epic | Commit | Content |
|---|---|---|
| A #1062 | `da08b7eb` | fail-closed atomic sync (no backfill, unconfirmed slots tracked + bannered with Retry, cache kept on holes), ingress barrier (messages held unbounded, raw sniffs bounded 64, flush post-sync), per-slot PSK identity diff (UI notice + warn log), unread preserved only on same PSK, fail-closed `_findChannelByIndex`, notification suppression for unconfirmed slots, self-retry on failed live sync |
| B #1063 | `b658fe14` | in-memory conversation dropped + reloaded under the new PSK on slot identity change; setChannel reassignment clear narrowed to legacy slot keys (PSK history survives re-add; deleteChannel keeps the full clear); write-side index fallback escalated to an error naming the orphaning consequence; stale #193-era comments corrected, setChannel/resolver interplay documented |
| C #1064 | `2a9d1e16` | the three integration scenarios below, the notify-decision test probe, store wiring test hook, and one fix the tests exposed (next section) |

## Gap found by the integration tests (fixed in `2a9d1e16`)
Epic A's flush documented that a held frame for a still-unconfirmed slot re-holds, but the handler only gated on the list-level barrier: after a PARTIAL sync completed, a held message for an unconfirmed slot would have filed by raw index against an unknown identity and persisted under the legacy index key. `_handleIncomingChannelMessage` now re-holds such frames until a sync confirms the slot. This is the "prove the check can fail" discipline paying for itself; the flaky-sync scenario below fails without the fix.

## Evidence
Machine verification, all on the stacked branch:
- `flutter analyze` clean on every touched file.
- Unit tests: 7 sync-truth tests (`test/connector/channel_sync_truth_test.dart`), 5 store identity tests (`test/storage/channel_message_store_identity_test.dart`).
- Integration tests (`test/connector/channel_slot_resync_integration_test.dart`):
  1. **#1060 bug validation (wipe + re-import, all three slots shuffled):** post-sync list matches the device exactly; all three identity changes surfaced; the old private conversation does not stay behind under #wardriving; a #test message files under #test and is notify-evaluated against #test's PSK (mode `all`); a #wardriving message is evaluated against #wardriving's PSK and its OFF mode rides along to the new slot. The reported symptoms (muted channel notifying, #test rendering in the private channel) cannot reproduce.
  2. **Manual device-side reorder:** a message persisted under Alpha's PSK follows Alpha to its new slot after the re-sync; nothing renders under Beta.
  3. **Flaky sync mid-reconnect:** a message for a never-confirmed slot is held, not filed by raw index, and no notify decision is made for it; after a confirming re-sync it files once, against the right PSK and mode.
- **Negative evidence:** with Epic B's drop/reload and the slot-level re-hold reverted in the working tree, all three scenarios fail (`+0 -3`) on exactly the guarded assertions; restored, all pass. The checks can fail.
- Full suite at Epic B: 1791 passed / 1 skipped, exit 0. Full suite at Epic C: 1794 passed / 1 skipped, exit 0.

## Decisions logged
- Epic B re-scope approved by the owner 2026-11-03 ("Agree, proceed"); storage was already PSK-keyed since #194, so no migration was needed.
- Already-miskeyed rows from the #1060 window stay as-is: not mechanically separable, and the owner's standing history-loss bar is deliberately low. Say the word and a per-radio clear can be added instead.
- setChannel reassignment now PRESERVES the outgoing occupant's PSK-keyed history (only legacy slot keys are purged). Re-adding a channel later restores its messages; this strengthens #194's intent and the diff is one call site, flagged for owner review on the Epic B PR.
- Owner, 2026-11-03 in chat: "I don't have a way to reproduce right now. Push/pr if the work is done, we will validate in live testing." The pre-PR hardware gate is waived for this feature; validation moves to live testing. Merges still require the explicit per-PR grant.

## Open until the owner closes them
- Live-testing validation after merge (the #1060 recovery sequence: wipe, re-import, reconnect, one sync). The owner cannot reproduce on demand right now, so this is observational.
- The user-reported problem the owner logged this feature against: its one-liner / issue number is still pending and will be linked under #1063/#1064 when provided.
- Merges of the stacked PRs (A into dev, then B+C) on the owner's explicit grant.
- #1060 closes only after the owner confirms the fix in live use.

Agent: TurquoiseBridge (session 82d77b2f)
