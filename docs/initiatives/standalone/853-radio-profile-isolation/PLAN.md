# Feature PLAN: radio-profile isolation

| | |
|---|---|
| **Feature** | [#853](https://github.com/OffbandMesh/meshcore-client/issues/853) · Citadel task minted on merge |
| **Serves** | No parent Initiative; a standalone Feature. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-20 |

## At a glance

- **What:** every piece of client state that belongs to a specific radio is scoped to that radio, and every surface that stays global is global **on the record** rather than by accident.
- **Why now:** the owner runs twelve radios through one client. Eleven stores already scope correctly, so what is left are leftovers, and leftovers rot: #754 and #471 sat written-but-unmerged for four days because this Feature had no plan, so no chain could run them.
- **How:** a harness that makes the verdict mechanical, then one consolidated migration for the three remaining global surfaces, then the two smaller jobs, then integration testing.
- **Done when:** a test fails if any persistence surface lacks a declared scoping verdict, and on hardware radio A's data never appears while radio B is connected, across a switch and a restart.

## 1. Diagnosis

Verified against `dev` at `b59bc728`, which is after tonight's #917 storage rewrite and after #754 and #471 landed. The audit in #853's body was taken at `a69cb998` and parts of it have moved since; the rows below supersede it.

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Twelve stores already scope by the connected radio's key prefix and are correct | `channel_message_store`, `message_store`, `channel_store`, `channel_order_store`, `channel_region_scope_store`, `channel_settings_store`, `contact_store`, `contact_settings_store`, `contact_group_store`, `community_store`, `unread_store`, `block_store` all read `publicKeyHex` | The mechanism works. This Feature closes leftovers, it does not redesign |
| 2 | `contact_discovery_store` was the last store-level hole and is now fixed | #754, merged `a331075a` | One hole closed, and the pattern it used (orphan the untagged legacy blob, let it self-heal) is the precedent for choice 1 below |
| 3 | `path_history_<contactPubKey>` is keyed by contact only, so a learned mesh route bleeds between any two radios that share a contact | `storage_service.dart:51`, `path_history_service.dart:360,411,472` | #854. A route learned by a 1 W handheld gets applied to a repeater, and the reverse |
| 4 | `path_history_` is also unbounded in SharedPreferences: **2,041 keys, 3,652,667 bytes, 86% of a 4.23 MB prefs file**, while `PathHistoryService` caches only 50 | measured on the owner's live prefs, 2026-10-19 | #924. And since every prefs write re-encodes the whole file (#923, 49.4 ms on Windows), this one store makes every unrelated settings write about seven times slower |
| 5 | `delivery_observations` is one global list feeding the ACK-timeout ML model, so one radio's RF timing trains another radio's predictions | `storage_service.dart:166`, `timeout_prediction_service.dart:46,92`; 3,091 bytes, 14 entries on the owner's install | #856. Silent accuracy loss rather than a visible failure, which is why nobody reported it |
| 6 | `pending_messages` is **dead code**: `loadPendingMessages`, `savePendingMessages` and `clearPendingMessages` have no callers anywhere in `lib/` or `test/`, and the key is absent from the owner's live prefs | `grep -rn "PendingMessages\|pending_messages" lib/ test/` returns only the three definitions; the `_pendingMessages` field at `message_retry_service.dart:547` is an unrelated in-memory list | #855 does not need scoping. It needs deleting |
| 7 | The scope key is set from the SELF_INFO handshake, so a read issued before it lands uses the **previous** radio's prefix | #158, confirmed in source at `meshcore_connector.dart` and `channels_screen.dart`; desktop-only, does not reproduce on Android | A different defect class from rows 3 to 6: these stores are scoped correctly and still bleed, through timing |
| 8 | #190's named root cause is already addressed, yet #190 is still open as an in-progress epic | #190 blames slot-index keying with no PSK binding; `channel_message_store._storageKey()` now resolves PSK first and logs loudly on the index fallback (#194), and #472 closed the cross-radio case | Needs a **verdict**, not an assumption. Either it no longer reproduces, or what remains is narrower than its body says |
| 9 | Three surfaces are global **on purpose** and must not be "fixed" | `client_id_store` (`client_install_id`, the app install identity); `repeater_passwords` and `repeater_auto_clock_sync_after_login` (keyed per repeater **node**, not per connecting radio); theme, language, units, map prefs | Without a recorded verdict a future audit re-opens these as holes, which is exactly how time gets wasted |
| 10 | Nothing makes any of this checkable | #853's acceptance says the Feature closes when "every store has a verified scoping verdict", and the only way to check that today is to re-read the audit by hand | A new global key can land tomorrow and nothing notices. Same lesson as #927: a prose guard does not gate |

**Root cause of the *pattern*, as distinct from the individual bugs:** there is no mechanical statement of what each surface's scoping is meant to be, so correctness lives in an issue body and decays.

## 2. Scope

**In:**
- A machine-checkable scoping verdict for every persistence surface, which is #853's acceptance bar made executable.
- #854 path history per radio, and out of SharedPreferences, which also resolves #924.
- #855 dead `pending_messages` API removed.
- #856 delivery observations per radio.
- #507 Settings to Blocked per-radio view, plus its T1000e hardware validation.
- #158 the stale-scope read window, and a verdict on #190.
- Recorded global-on-purpose verdicts for the surfaces in diagnosis row 9.

**Out:**
- **#923**, the 49 ms cost of a single SharedPreferences write on Windows. Epic B shrinks its blast radius considerably by removing 86% of the prefs file, but the mechanism is untouched and #923 stays open. Fixing it properly means moving the remaining keys or batching writes, which is its own work.
- Refactoring the twelve already-correct stores onto a shared scoping helper. The pattern is duplicated and the rule of three would justify a helper, but rewriting working per-radio storage carries real data risk for no user-visible benefit.
- #660 and #280. #853's own body excludes them as "related but not isolation, not parented here", and that is still right: #660 is radio-side contact loss, #280 is message ordering.
- Any firmware or wire-format change. This Feature is entirely client-side.

## 3. Epics

Tasks are 3 to 4 points. Each Epic ends with a verification task and gets one PR. Epic A reproduces the diagnosis as failing tests before anything is built.

### Epic A: [#936](https://github.com/OffbandMesh/meshcore-client/issues/936) scoping-verdict harness and failing repros

| Task | Pts |
|---|---|
| **A1 · Surface inventory with declared verdicts:** a test that enumerates every persistence surface (drift key prefixes and prefs keys) against a declared table of `perRadio` or `globalOnPurpose(reason)`. It fails on an unclassified surface and on a new global key. Proven by adding a fake global key in the test and watching it go red | 4 |
| **A2 · Reproduce rows 3 and 5 as failing tests:** radio A's path history visible to radio B, and radio A's delivery observations feeding radio B's model. Both red before Epic B touches anything | 3 |
| **A3 · Epic verification:** the harness fails for the right reasons and passes for the current declared set, with A2's two repros red | 1 |

### Epic B: [#937](https://github.com/OffbandMesh/meshcore-client/issues/937) the three global `storage_service` surfaces, as one migration

| Task | Pts |
|---|---|
| **B1 · Delete the dead `pending_messages` API** (#855): three methods and the key, with the harness updated so the surface leaves the inventory rather than being reclassified | 3 |
| **B2 · Path history per radio, in drift** (#854 and #924): scope by radio prefix, move the store from SharedPreferences to `BlobStore`, bound what persists to what `PathHistoryService` actually caches, and **delete the 2,041 legacy untagged keys once the readback gate passes** (decision 1) | 4 |
| **B3 · Delivery observations per radio** (#856): scope by radio prefix so the model trains per radio, and **delete the legacy global list** (decision 1) | 3 |
| **B4 · Epic verification:** A2's repros now pass, the inventory shows no unclassified surface, and the owner's real prefs file is measurably smaller with route history intact | 1 |

### Epic C: [#938](https://github.com/OffbandMesh/meshcore-client/issues/938) Blocked per-radio view

| Task | Pts |
|---|---|
| **C1 · The view** (#507): Settings to Blocked lists the connected radio's blocks, with an explicit disconnected state and an explicit empty state that read differently from each other | 3 |
| **C2 · Isolation and clear tests:** a block on radio A is absent on radio B, and a clear sticks across a restart | 3 |
| **C3 · Epic verification:** hardware on the T1000e, confirming the re-clear behind #471 does not recur | 1 |

### Epic D: [#939](https://github.com/OffbandMesh/meshcore-client/issues/939) scope-key lifecycle, the stale-read window

| Task | Pts |
|---|---|
| **D1 · Verdict on #190** (diagnosis, no code): does its reproduction still reproduce after #194 and #472? Close it, or re-scope it to what actually remains, with evidence either way | 3 |
| **D2 · Close the stale-read window** (#158): no per-radio read resolves against a stale or unset prefix. Fail closed, returning nothing rather than the previous radio's data | 4 |
| **D3 · Epic verification:** a switch between two radios with no window in which a read can see the wrong prefix, proven by test and on desktop where #158 was seen | 1 |

### Epic E: [#940](https://github.com/OffbandMesh/meshcore-client/issues/940) Integration Testing

| Task | Pts |
|---|---|
| **E1 · The full matrix:** for every surface in the inventory, radio A's datum isolated and not inherited by radio B, across a radio switch **and** an app restart, which is #853's stated acceptance bar | 4 |
| **E2 · Hardware validation:** two real radios on the owner's own install, including the twelve-radio database already on his machine | 3 |
| **E3 · Epic verification and Feature closure:** the inventory is complete, every verdict recorded, no hole left | 1 |

## 4. Order and dependencies

**A, then B, then C and D in either order, then E.**

- **A is first** because it is the base diagnostic: without it, B's fixes cannot be shown to have fixed anything, and it is the only task that prevents recurrence.
- **B is second** because it is the largest hole and the only one with a cost a user feels today, both the route bleed and the prefs-file tax on every other settings write.
- **C and D are independent** of each other and of B. C touches `lib/screens/`, D touches the connector and the scope-key plumbing, neither touches `storage_service.dart`.
- **E is last** by canon: a Feature's final Epic is Integration Testing of the whole integrated environment.

**File overlap:** only B touches `lib/services/storage_service.dart`, and it touches it three times inside one Epic instead of across three PRs, which is the whole reason these were consolidated. D touches `lib/connector/meshcore_connector.dart`, the most contended file in the repo, so D should not run alongside other connector work.

## 5. Grants and authorization

What merging this plan authorizes, in words:

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Building all five Epics end to end with no further approval, opening one PR per Epic | The chain model that worked for #917: one approval, unattended run, merges held |
| **Merges** | 5, one per Epic | Tasks are commits on the Epic branch, so there is no per-task PR. Five Epics, five PRs |
| **Epic verification** | `owner` | Three of the five end in a judgement only the owner can make: hardware on the T1000e (C), a real two-radio switch (D and E), and whether route history survived the move (B). A command here would be a check that cannot fail |
| **Owner steps during the run** | Two, both late: the T1000e check for C and the two-radio switch for E, one message each | Everything else, including the migration rehearsal against a copy of his real database, runs without him |
| **Stops** | A refused migration readback, a harness failure this plan did not predict, or any sign of lost route history | Each is a data-integrity signal, and each stops rather than proceeding |
| **Flash** | `null` | Nothing here touches firmware. The T1000e check uses whatever is already on it |

```grant-terms
{
  "epic_chain": [936, 937, 938, 939, 940],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 5, "basis": "one merge per Epic in the chain (936, 937, 938, 939, 940); Tasks are commits on the Epic branch, so there is no per-task PR" },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

**Basis for the expiry.** 168 hours, the maximum, because Epics C, D and E each end in an owner hardware step and the owner has a day job. #917's 72 hours was enough only because its single owner step came at the very end; a grant that expired between Epic C's hardware check and Epic D's would break the chain and need a re-mint for no reason.

## 6. Can't-tell branches

| Where | Can't tell what | Does |
|---|---|---|
| Legacy untagged `path_history_<contact>` key | which radio learned this route | **stop** — never assign it to a radio. Per decision 1 it is deleted, not guessed at, and only after the per-radio readback gate passes |
| Legacy untagged `delivery_observations` | which radio produced these observations | **stop** — same. Deleted per decision 1; mixed-radio data is worse than no data for the model |
| Per-radio read with an empty or unset scope prefix (#158) | which radio is connected | **stop** — return nothing, never fall back to the last known prefix. This is the #754 precedent: an unset key loads nothing and never writes |
| A surface in the inventory with no declared verdict | whether it should be per-radio | **stop** — the harness fails the build. That is the point of A1 |
| Path-history migration readback mismatch | whether every route survived the move into drift | **stop** — keep the prefs copy, delete nothing, surface loudly. Same gate as #920, which caught a lossy converter precisely because the count was measured independently of the converter |
| `repeater_passwords`, keyed by repeater node | nothing: this one is **decidable**, and the verdict is global-on-purpose | proceeds, by recorded verdict rather than by silence. Not a fail-open branch |

No fail-open branches. Nothing in this plan needs a fail-open grant.

## 7. Verification

- **Named command:** `flutter test test/storage/ test/services/ test/connector/` plus `flutter analyze`, with the scoping-inventory test named explicitly in each Epic's PR body.
- **Acceptance bar:** the inventory test fails when a surface is unclassified or a new global key appears, proven by making it fail on purpose; Epic A's two repros go red to green across Epic B; and on hardware, radio A's data never appears while radio B is connected, across a switch and a restart.

## 8. Done when

- Every persistence surface has a declared verdict, `perRadio` or `globalOnPurpose` with a reason, and a test fails if one does not.
- #854, #855, #856, #507 and #158 are closed, and #190 has a recorded verdict.
- #924 is closed as a side effect of B2.
- On the owner's own twelve-radio install, a radio switch and a restart show no data belonging to any other radio.

## 9. Decisions

Settled by the owner, 2026-10-20. No open choices remain in this plan.

| # | Decision | What it means for the build |
|---|---|---|
| 1 | **Delete the legacy untagged data.** The 2,041 `path_history_<contact>` keys and the global `delivery_observations` are removed, not orphaned | B2 and B3 each delete their legacy key **only after** the per-radio readback gate passes. Both surfaces are regenerable: routes relearn in normal use and the ML model retrains. This is also what reclaims 86% of the prefs file |
| 2 | **Path history moves into drift**, not just a radio prefix in place | B2 is a store move plus a scoping change in one migration, following #335's precedent for messages and contacts. Resolves #924, and cuts most of #923's per-write cost as a side effect by shrinking the file every other write re-encodes |
| 3 | **#158 and #190 stay in this Feature**, as Epic D | The Feature cannot claim isolation while a read can still resolve against a stale prefix. A user cannot tell "wrong store" from "right store, wrong moment" |

Decision 1 differs from #754's choice to orphan, deliberately: that blob was small, whereas here the orphaned data *is* the performance problem.

## 10. Carried-in work

| Item | Goes to |
|---|---|
| #854 path history per radio | Epic B, task B2 |
| #855 pending messages | Epic B, task B1, **as a deletion** rather than a scoping fix |
| #856 delivery observations | Epic B, task B3 |
| #924 `path_history_` unbounded (filed 2026-10-19) | Epic B, task B2, the same change as #854 |
| #507 Blocked per-radio view | Epic C |
| #158 history bleed after a radio switch | Epic D, task D2 |
| #190 history bleed into a new channel | Epic D, task D1, as a verdict |
| #923 prefs write cost | **Out of scope.** B2 shrinks its blast radius; the mechanism is untouched and the issue stays open |

## Alternatives considered but not chosen

- **One shared scoping helper across all twelve stores.** The rule of three would justify it, but rewriting working per-radio storage risks data for no user-visible gain.
- **Three separate PRs for #854, #855 and #856.** How they were filed, and the reason this plan exists. They share a file, a defect and a migration decision, and splitting them triples the review and test rounds while hiding that one of the three is dead code.
- **A commit hook blocking any new global prefs key.** Mechanical, but it would fire on every legitimate global setting. A1's inventory test achieves the same thing where the knowledge belongs, in a declared table beside the code.

When this plan merges, each Epic's Tasks get a GitHub issue and a Citadel task, per canon.
