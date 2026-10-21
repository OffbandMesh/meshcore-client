# Feature PLAN: storage save path: remove O(history) work per message

| | |
|---|---|
| **Feature** | [#917](https://github.com/OffbandMesh/meshcore-client/issues/917) · Citadel `meshcore-open-1hf` |
| **Serves** | No parent Initiative; a standalone Feature. Resolves the cause behind [#334](https://github.com/OffbandMesh/meshcore-client/issues/334), the originating Epic, which stays open until this Feature's integration test proves the ANRs are gone. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-19 |

## At a glance
- **What:** stop re-encoding a channel's entire message history every time one message arrives. First move the work off the UI isolate (Epic A), then delete the work by storing one row per message (Epic B).
- **Why:** 25 ANR clusters on Play since September, all `Input dispatching timed out`. The cost grows linearly with history, so it worsens for exactly the users who use the app most. ANR rate is also the Android vitals signal Google uses to suppress an app in Play search, and Offband is currently absent from search for "meshcore" while ranking first for "offband".
- **How:** entirely client-side. No firmware change. Three Epics in order: A isolate offload, B normalise to rows with a migration, C hardware integration test.
- **Done when:** receiving a message costs the same at 50,000 messages of history as at 50, no message is lost in the migration, and the owner confirms on hardware on Android and Windows.

## 1. Diagnosis

All figures measured 2026-10-19 against the owner's live database and the real Dart VM. Full evidence: [#334 comment](https://github.com/OffbandMesh/meshcore-client/issues/334#issuecomment-6262727767).

| # | Finding | Evidence |
|---|---|---|
| 1 | `StoredBlobs` is `key TEXT PRIMARY KEY, value TEXT`: one JSON blob per store key | `lib/storage/drift/offband_database.dart:347` |
| 2 | Live DB is 41.03 MB: 151 rows, 39.21 MB of JSON. Largest row is 5.38 MB holding **9,230 messages** in one channel | `select key, length(value) from stored_blobs` on a copy of the live DB |
| 3 | Saving one message decodes the whole blob, rebuilds every record, re-encodes the whole blob | `channel_message_store.dart:80-104`, `message_store.dart:33-57` |
| 4 | That costs **134 ms** on a desktop CPU: decode 50, rebuild 38, encode 51 | Dart benchmark, real 5.39 MB payload, median of 5 |
| 5 | Cost scales linearly: ~14 ms per 1,000 records of history, per message | 500 recs 4 ms, 1k 12 ms, 2.5k 26 ms, 5k 83 ms, 9,230 130 ms |
| 6 | Appending one record instead costs **0.002 ms**, so the current path does **67,000x** more work per message | Same benchmark, single-record encode, median of 200 |
| 7 | Bursts serialize: `BlobStore.synchronized` chains futures per key, so N messages each pay full cost | `blob_store.dart:58-62` |
| 8 | 5 messages on a 10x slower device is **6.7 s**, past the 5 s ANR watchdog | Arithmetic on finding 4. **Not reproduced on a device**; see Risks |
| 9 | Each cycle allocates ~11 MB of strings plus 9,230 maps, which is why traces are dominated by GC frames | `ScavengerVisitor`, `MarkingVisitor`, `FreeList::TryAllocate`, `String::ConcatAllRange` in 25 clusters |
| 10 | **#335 did not fix this.** It moved the bytes into SQLite; the JSON stayed. ANRs span version codes 65, 66 and 67, all post-drift | Play Reporting API clusters by `lastAppVersion` |
| 11 | **SQLite was never on the UI isolate.** `drift_flutter` 0.3.1 hosts connections in a background isolate; web uses `drift_worker.js` | `drift_flutter-0.3.1/lib/src/connect.dart` |
| 12 | Only 9 distinct users affected, 1 per cluster, consistent with cost scaling by history | `distinctUsers` on every cluster |

**Root cause:** O(entire history) work per message, serialized across a burst, with GC pressure compounding it.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Fix the isolate first or normalise first | Isolate first | Stops the ANRs and the Play penalty with zero data risk, and buys time to do the migration carefully |
| Is the isolate offload sufficient | No | It relocates ~11 MB of allocation per message rather than removing it. Total work unchanged |
| Isolate granularity | One `Isolate.run` around the **whole** read-modify-write | Only two strings cross the boundary. Wrapping encode and decode separately would ship the object graph across twice |
| Where the helper lives | `BlobStore` | One place, so stores change call shape instead of each growing its own isolate wrapper |
| Migration safety | Additive. Blob retained until per-key readback matches | #355 cost 574 messages after the last storage migration shipped in a day |
| Retype #334 | No | #917 is the Feature and carries this plan. #334 stays as the originating Epic and closes on the integration test. Less board churn |

## 3. Epic chain

### Epic A: blob read-modify-write off the UI isolate

One helper in `lib/storage/drift/blob_store.dart` that runs the entire read, decode, merge, encode, write inside a single `Isolate.run`, taking the raw JSON string in and returning the merged string out. Then call-shape changes in `channel_message_store.dart`, `message_store.dart` and `lib/services/storage_service.dart` (11 JSON call sites). Smaller stores follow only if measurement says they matter.

**Epic verification:** the benchmark harness shows main-isolate block time at or near zero against the real 5.39 MB payload, and the owner confirms a burst no longer freezes the UI.

#### Epic A outcome, 2026-10-19

Built as A1 (`BlobStore.mergeOffThread`), A2 (DM save), A3 (both explicit delete paths), A5 (verification). Measured against the owner's real largest channel, 5,650,194 chars / 9,230 messages, on a desktop:

| | UI blocked | wall | heartbeats |
|---|---|---|---|
| 1 save, inline (pre-#919) | 381 ms | 381 ms | 1 |
| 1 save, off-thread | 44 ms | 297 ms | 174 |
| 5 saves, inline | 1,385 ms | 1,385 ms | 1 |
| 5 saves, off-thread | 66 ms | 1,496 ms | 964 |

Wall time barely moves, as predicted. Inline, the blocked time equals the whole operation. The burst case is now measured rather than arithmetic, though still on desktop hardware; the device check remains the owner's.

**A4 (`storage_service.dart`) was measured and declined**, which is this section's "smaller stores follow only if measurement says they matter" resolving to no. The largest value that file touches is 20,907 bytes (`path_history`, from the owner's live prefs); it costs 0.22 ms inline and 0.48 ms through `Isolate.run`, so converting those 11 call sites would add 2.2x the work. Full numbers: [#919 comment](https://github.com/OffbandMesh/meshcore-client/issues/919#issuecomment-6269611306).

That measurement turned up two things outside this Feature's shape, filed rather than absorbed:

- [#923](https://github.com/OffbandMesh/meshcore-client/issues/923): on Windows, one `SharedPreferences` write costs **49.4 ms on the UI isolate**, because `shared_preferences_windows` is pure Dart and re-encodes plus rewrites the whole file per key. Measured against the owner's live 4.23 MB prefs.
- [#924](https://github.com/OffbandMesh/meshcore-client/issues/924): `path_history_` is unbounded on disk, 2,041 keys and 86% of that prefs file, which makes every write in #923 worse over time.

Both are children of #334 and neither is fixed by this Feature.

### Epic B: normalise messages into rows

A real drift table beside `StoredBlobs`, one row per message. A save becomes an INSERT; reads page. Both message stores' read and write paths rewritten. An additive migration that never deletes a blob until readback proves the per-key count matches.

**Epic verification:** per-key message counts identical before and after on a copy of the real 41 MB database, and the benchmark shows per-message cost flat across history length.

#### Epic B outcome, 2026-10-19

Built as B1 (`message_records` at schema 2 plus a row API), B2 (both stores on rows), B3 (the per-key migration and its gate), B4 (verification). Run against a copy of the live 41.17 MiB database:

| | |
|---|---|
| keys migrated | **138 of 138** |
| records in blobs | 64,883 |
| rows stored | **64,883** |
| elapsed | 4,382 ms |

Exact parity, no refusals, and every blob byte-identical afterwards (length and content hash per key).

Per-message save cost against history length, median of 20:

| history | one more save |
|---|---|
| 500 | 0.124 ms |
| 5,000 | 0.126 ms |
| 50,000 | 0.133 ms |

A hundred times the history for 1.07x the cost, against 381 ms of UI block at 9,230 messages on the blob path. The Feature's "done when" is met.

One-time migration of the worst key (5.38 MiB, 9,230 messages), measured with a production-shaped background-isolate connection: **UI blocked 64 ms, wall 447 ms**. So the first open of the biggest channel after this ships costs one 64 ms hitch on a desktop.

**Two deliberate departures from this plan, both stricter or narrower, never looser:**

1. **The blob is never deleted**, not even on a verified match. This plan said "retained until per-key readback matches"; the implementation keeps it after the match too. Rows become the read and write path and the blob is left untouched, so the database temporarily holds both copies. Reclaiming that space is a separate owner-gated step, because the moment that delete runs is the moment a mistake stops being recoverable.

   > **Correction, 2026-10-21 (#943).** This section originally added that a downgrade to an older build "still finds its history where it looks for it". That is true of the **data** and false in **practice**, and the owner hit it: drift refuses to open a database whose `user_version` is newer than the binary's `schemaVersion`, so a pre-#917 build cannot open a migrated database at all. It never gets as far as the blobs it would have read.
   >
   > The consequence is a release one, not a desktop one: **once a user launches a schema-2 build they cannot go back to an earlier release.** A Play rollback or a halted staged rollout does not help anyone who already launched it, and the real fallback is an older build *plus* a pre-migration database copy, which loses everything received since. #943 carries the decisions (release-note wording, whether to tolerate a newer schema, whether the app should take its own pre-migration copy).
2. **One row per message with the per-message JSON in a `payload` column**, rather than a column per field. The migration is then a pure re-key with no field mapping that can silently drop or coerce a value, and the stores reuse their existing encoders verbatim. The trade, stated on the issue before building: message fields are not SQL-queryable. Columns can be added beside the payload later without another data migration.

### Epic C: Integration Testing

A and B together on real hardware, Android and Windows. Carries the test that validates #334 is dead, which gates closing it.

## 4. Interfaces

No protocol, wire-format or firmware change. No new dependency: `Isolate.run` is `dart:isolate`, and drift is already present. Storage schema change is internal and additive.

## 5. Secrets

None. This Feature touches no credential, key or external service.

## 6. Cannot-tell branches (standards#677)

| Branch | Behaviour |
|---|---|
| `Isolate.run` throws | **Stop.** Surface the error, leave the blob untouched. Never fall back to a silent main-thread encode |
| Blob is corrupt or not a JSON list | **Stop.** Do not overwrite. Log the key and byte length, keep the original |
| Migration readback count mismatch for a key | **Stop.** Keep the blob, delete nothing, surface loudly |
| Row insert fails mid-migration | **Stop** inside a transaction, roll back, keep the blob |
| Payload too large to send across the isolate | **Ask the owner.** Needs a measured threshold first; no guessed limit |

No fail-open paths. No branch proceeds on a condition it cannot confirm.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Migration loses messages | Additive, blob retained, per-key readback gate, test against a copy of the real 41 MB DB |
| The burst multiplier is arithmetic, not observed | Epic A's verification includes an owner device check. If a burst does not reproduce, the ANR cause is re-opened rather than assumed fixed |
| Isolate transfer cost exceeds the saving on small blobs | Measure before converting the smaller stores. Epic A converts the three big ones first |
| Play traces stay unresolvable | Out of scope here. Release builds strip Dart symbols, so no frame from this codebase appears in any trace. Retaining native debug symbols is a separate pipeline issue |

## 8. Owner steps

One, at the end of Epic A, and one at the end of Epic C: run the build on hardware and confirm the UI no longer freezes under a burst. Everything else, including the migration test, runs without him.

## grant-terms

The Epic chain is [#919](https://github.com/OffbandMesh/meshcore-client/issues/919) (A, isolate offload), [#920](https://github.com/OffbandMesh/meshcore-client/issues/920) (B, normalise to rows), [#921](https://github.com/OffbandMesh/meshcore-client/issues/921) (C, integration testing), merged in that order.

```grant-terms
{ "epic_chain": [919, 920, 921],
  "chain": true,
  "verification": {"mode": "owner"},
  "merge": {"budget": 3,
            "basis": "one merge per Epic in the chain (919, 920, 921); Tasks are commits on the Epic branch, so there is no per-task PR"},
  "expires_after_hours": 72 }
```

**Basis for the expiry.** 72 hours because Epic B carries a migration test against a copy of the real 41 MB database, and a grant that outlasts a careful run beats one expiring mid-chain and needing a re-mint.

**No flash or reset budget.** Nothing in this Feature touches a radio, so both keys are omitted and default to null.

**Verification is `owner` rather than a command** because two of the three Epics end in a judgement only the owner can make: that the UI no longer freezes under a burst on his device, and that nothing is missing after the migration. A command here would be a check that cannot fail, which the tool flags and which would verify nothing.
