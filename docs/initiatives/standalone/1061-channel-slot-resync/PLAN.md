# Feature PLAN: channel slot resync truth (#1060 class)

| | |
|---|---|
| **Feature** | [#1061](https://github.com/OffbandMesh/meshcore-client/issues/1061) · Citadel `meshcore-open-rwr` |
| **Fixes** | [#1060](https://github.com/OffbandMesh/meshcore-client/issues/1060) (P0): wipe + config re-import shuffled channel slots; notifications fired for a muted channel and messages rendered inside the wrong conversation |
| **Owner** | @Strycher |
| **Approved** | 2026-11-02 in chat: "Agree with all 4, don't hold on 4, do it now." Epic B re-scope approved 2026-11-03: "Agree, proceed." |

## At a glance
- **What:** make the device's channel list the only truth the client ever acts on, and make every piece of per-slot client state follow the channel's PSK identity instead of its reusable slot index.
- **Why:** #1060. The radio is authoritative for slot assignments; after a wipe + re-import the same channels can sit in different slots, and any client state keyed by slot silently attaches to the wrong channel.
- **Done when:** the integration scenarios pass (positive and negative), the #1060 reporter's sequence cannot recur, and the owner approves the OUTCOMES.

## 1. Diagnosis (#1060, verified in code)
Three routes let a stale slot map poison live behavior:
1. **Backfill:** the channel sync restored unanswered slots from `_previousChannelsCache`, so a shuffled device list came back part-fresh, part-stale.
2. **Index filing:** raw-RX and message ingress filed by slot index through the stale list.
3. **Poisoned resolver:** notify modes and persisted history are PSK-keyed (#839, #194), but both resolve PSKs through `_findChannelByIndex` - which consulted the stale list, so correct identity keying was fed wrong identities.

## 2. The four approved parts → Epics
| Part | Epic | Scope |
|---|---|---|
| 1. Fail-closed, atomic channel sync | A [#1062](https://github.com/OffbandMesh/meshcore-client/issues/1062) | never backfill an unanswered slot; unconfirmed slots tracked + surfaced (banner w/ Retry); cache not overwritten on holes; self-retry on a failed live sync |
| 2. Ingress barrier | A #1062 | no live channel frame files until THIS connection confirms the list; pull-based message frames held unbounded (the radio already popped them), raw sniffs bounded at 64; held frames flush post-sync |
| 3. Per-slot identity diff | A #1062 | PSK diff per slot against the last truth; identity changes surfaced in UI + log; unread preserved only on same PSK; unconfirmed slots fail closed in `_findChannelByIndex` and suppress notifications |
| 4. Identity-keyed message state | B [#1063](https://github.com/OffbandMesh/meshcore-client/issues/1063) | RE-SCOPED (see below) |
| Validation | C [#1064](https://github.com/OffbandMesh/meshcore-client/issues/1064) | end-to-end scenarios, the #1060 bug-validation test, this folder's OUTCOMES.md |

## 3. Epic B re-scope (approved 2026-11-03)
Part 4 was planned as "re-key channel_message_store by PSK with migration" from a stale #193-era comment. The store has been PSK-keyed since #194; the incident's cross-wiring came from the poisoned resolver (route 3), which Epic A fixes. Epic B therefore shrank to:
1. drop a slot's in-memory `_channelMessages` entry on identity change and reload it under the new identity's PSK;
2. harden the store's slot-index write fallback (error log naming the orphaning consequence);
3. narrow setChannel's reassignment clear to the LEGACY slot keys only, so the outgoing occupant's PSK-keyed history survives and returns if the channel is re-added;
4. correct the stale #193-era comments and document the setChannel/resolver interplay.

Already-miskeyed rows from the #1060 window stay as-is (not mechanically separable; owner's standing low history-loss bar).

Agent: TurquoiseBridge (session 82d77b2f)
