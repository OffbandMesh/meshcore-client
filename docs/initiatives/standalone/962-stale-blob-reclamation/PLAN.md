# Feature PLAN: reclaim the stale post-migration message blob

| | |
|---|---|
| **Feature** | [#962](https://github.com/OffbandMesh/meshcore-client/issues/962) · Citadel `meshcore-open-8xj` |
| **Serves** | Follows the #917 storage rewrite. #917's plan deferred this as "a separate owner-gated step, because the moment that delete runs is the moment a mistake stops being recoverable." The owner opened that gate on 2026-10-22. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-22 |

## At a glance

- **What:** each migrated message key gets a timestamp; **30 days** later its stale blob is deleted, with a Settings action to do it immediately.
- **Why now:** schema 2 has not shipped. Every install that takes it will hold its message history twice, and the fix can be in place before anyone receives it.
- **How:** Epic A writes the timestamps and the sweep, Epic B the manual action, Epic C the owner's hardware check.
- **Done when:** a key migrated more than 30 days ago has no blob, the file has actually shrunk, and a key whose re-verify fails still has its blob.

## 1. Diagnosis

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | The migrated blob goes **stale**: nothing writes it after a key is marked. | Every blob write is in the fallback branch behind an early `return` in the migrated branch: `channel_message_store.dart:175,235`, `message_store.dart:111,152`. | The blob is a frozen snapshot at the migration moment, not a mirror. Deleting it costs the pre-migration snapshot and nothing else. |
| 2 | Nothing ever deletes it. | No caller removes a migrated history blob. `ensureMessageRowsMigrated` documents "**The blob is never deleted**, not even on a verified match." | The database holds the history twice, permanently. |
| 3 | `DELETE` frees **no disk space**. | Measured on a copy of the owner's database: 74,350,592 bytes before, **74,350,592 after** deleting all 40 migrated blobs. | A sweep without `VACUUM` reclaims nothing the user can see. |
| 4 | `VACUUM` reclaims it, cheaply. | Same copy: 54,919,168 bytes after, **-18.5 MiB in 0.6 s**, `integrity_check ok`, all 28,386 rows intact. | One `VACUUM` after a sweep is the whole win. |
| 5 | Migration is **lazy and per key**. | The owner's install had 40 keys migrated (16.2 MB of blob) and **98 not** (23.8 MB), because those radios had not been reconnected. | An install-wide clock would delete nothing for a long time, then a lot at once. The marker must be per key. |
| 6 | The marker holds no timestamps. | `__msgrows_migrated` is `jsonEncode(keys.toList())`, a flat array (`blob_store.dart:281`). | There is nothing to age a key against today. |
| 7 | Some blobs are **not** reclaimable and must not be touched. | `contacts*`, `discovered_contacts*`, `path_history_*` have no row equivalent; the blob IS their storage. 2.0 MB on his install. | The sweep must be restricted to migrated message-history keys. |
| 8 | Clearing history already removes both copies. | `clearChannelMessages` calls `deleteEverywhere` **and** `deleteMessageRows` (`channel_message_store.dart:361,372`). | No stale-history-after-delete hole to fix. Checked because it would be worse than wasted space. |
| 9 | Losing the marker after deletion is survivable. | `blob_store.dart:340`: an empty or absent blob re-marks the key and reads rows. | Deletion does not create a new single point of failure beyond the rows themselves. |
| 10 | It affects users, not just this install. | ~175 active Android installs (173 on 2026-10-17, Play installs overview) plus desktop. Schema 2 is on `dev` at `4d4d44a6` and absent from v1.6.0. | Shippable before anyone is exposed. |
| 11 | `VACUUM` removes nothing. It reclaims only pages the deletes already freed. | Measured on a copy: 40 migrated blobs deleted, 291 keys kept **including all 98 unmigrated history blobs**, each hashed before and after. 0 missing, 0 byte-changed, 0 unexpected; rows 28,389 to 28,389; file 74,350,592 to 54,927,360; `integrity_check ok`. | **All the risk is in the DELETE selection, none in `VACUUM`.** The safety budget belongs on the per-key re-verify and the key-pattern restriction, which is where this plan puts it. |

**What the snapshot does and does not protect**, so this is not mistaken for removing a backup: it protects the *pre-migration* history against a migration or read-path bug found later; it protects **nothing** that arrived since, which is single-copy from the instant it lands either way; and its coverage decays as new messages accumulate.

## 2. Scope

**In:**
- A per-key migration timestamp, including a backfill for keys already migrated when this ships.
- An automatic sweep, **once per launch**, that deletes a stale blob once its key is older than 30 days, re-verifying the key immediately before each delete rather than trusting the marker.
- One `VACUUM`, only after a sweep that actually deleted something.
- A Settings action, "Clear Stale History Now", reporting bytes before and after.

**Out:**
- The retention limit (discarding history the user has only one copy of): #963, deliberately later.
- Blobs for keys that have **not** migrated. Those are authoritative.
- `contacts*`, `discovered_contacts*`, `path_history_*`. The blob is their storage.
- Any backup or export story for rows. Raised and not asked for.
- Reclaiming the SharedPreferences legacy copies. #853 already purged those.

## 3. Epics

### Epic A: the timestamp and the sweep

| Task | Pts |
|---|---|
| **A1 · Reproduce the diagnosis as failing tests:** a key migrated long ago still has its blob; the marker carries no timestamp; `DELETE` without `VACUUM` leaves the file size unchanged. Red before anything is built. | 3 |
| **A2 · Per-key timestamps:** a `__msgrows_migrated_at` blob mapping key to epoch ms, written when a key is marked. Pre-existing migrated keys are **stamped on first sight**, not treated as eligible, so no blob is deleted the moment a user updates. | 3 |
| **A3 · The sweep:** for each migrated message-history key older than the 30-day constant, re-run the superset check (every blob record present as a row) and delete the blob **only** on a pass. Restricted to `channel_messages_*` and `messages_*`. Wired to run **once per launch**, after startup settles, never mid-session. | 4 |
| **A4 · One `VACUUM`,** only if the sweep deleted something, with the reclaimed byte count logged. | 3 |
| **A5 · Epic verification:** the named command, plus the sweep run against a copy of a real database. | 1 |

### Epic B: "Clear Stale History Now"

| Task | Pts |
|---|---|
| **B0 · Mock-ups FIRST, owner-approved before any of it is built.** Every state of every new surface, as a committed HTML file beside this plan, in the format the firmware initiative uses: numbered variants, real chrome and tokens, example values from the owner's own install, and the behaviour to build as bullets under each. **Added 2026-10-23, after this Epic's UI was built and installed on both his machines without him ever seeing the design.** The plan had no such step, which is why that happened. | 2 |
| **B1 · The action** in Settings, showing database size before and after and how many keys were cleared, with the same re-verify and refusal path as the sweep. Per decision 4 it **reports keys it refused** in the result, not just the log: "cleared 12, kept 1 that failed verification". | 3 |
| **B1a · A confirmation stating the scope** before anything is deleted: how many copies, roughly how much space, how many messages are *not* affected, and that it cannot be undone. Needs a **preview pass** in the sweep, verifying every eligible key and totalling it without deleting, so the numbers are real rather than estimated. Verification then runs twice for a confirmed clear, once to preview and once under the key lock. That is the price of saying what will go before it goes. Owner-required 2026-10-23. | 3 |
| **B2 · Widget tests:** the action with nothing eligible, with eligible keys, and with a key whose re-verify fails (which must report a refusal rather than silence). Plus the confirmation: it states the scope, Cancel deletes nothing and leaves the action usable, a forecast refusal is shown before the press, and nothing eligible opens no dialog at all. | 3 |
| **B3 · Epic verification** | 1 |

### Epic C: Integration Testing

| Task | Pts |
|---|---|
| **C1 · Owner hardware run,** Windows and Android: the action reports a real reduction, history still reads correctly afterwards, and an unmigrated radio's history is untouched when that radio is next connected. | 3 |
| **C2 · Post-run read-back** of the live database: no migrated key retains a blob, unmigrated keys all do, row count unchanged. | 1 |

## 4. Order and dependencies

A before B: the action is a manual trigger for the sweep A builds, so building B first would mean writing the engine twice. C last, per canon, and it is the only Epic needing the owner.

A and B both touch `blob_store.dart`; B also touches the Settings screen and ARB files. No overlap with #963, which should follow this rather than lead it (see its fourth open question: a row trim makes the blob a superset of the rows, which is this sweep's refusal condition, so the two must agree on authority or a trim permanently blocks reclamation the way #952 did).

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Building Epics A, B and C, and merging one PR per Epic. | Three Epics, three PRs. |
| **Merges** | 3 | One per Epic. Tasks are commits on the Epic branch, so there is no per-task PR. |
| **Epic verification** | Owner approves each Epic's PR. | A destructive data operation. Each Epic's PR should be looked at, not auto-verified by a command. |
| **Owner steps during the run** | Epic C only. | A and B are test-provable; only the real-hardware reduction needs him. |
| **Stops** | Any key whose re-verify fails. The sweep keeps that blob, logs loudly, and never retries into a loop. | The #952 lesson: a refusal that silently repeats forever is worse than a loud one. |
| **Flash** | None. | No firmware. |

```grant-terms
{
  "epic_chain": [965, 966, 967],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 3, "basis": "one merge per Epic (A the timestamp and sweep, B the manual action, C Integration Testing); Tasks are commits on the Epic branch, so there is no per-task PR" },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

**`epic_chain` filled 2026-10-23:** [#965](https://github.com/OffbandMesh/meshcore-client/issues/965) (Epic A, the timestamp and sweep), [#966](https://github.com/OffbandMesh/meshcore-client/issues/966) (Epic B, the manual action), [#967](https://github.com/OffbandMesh/meshcore-client/issues/967) (Epic C, Integration Testing). All three are sub-issues of #962, with Citadel tasks `meshcore-open-5vt`, `-gan` and `-2jd` chained A to B to C.

It was left empty when this plan first merged, which was a sequencing mistake: `grant.py` requires a non-empty chain, so the plan as merged could not have minted a grant and this follow-up was needed. The Epic issues should exist before a plan PR merges.

**Basis for the expiry.** 168 hours, the maximum. Epic C ends in an owner hardware step on two platforms and he has a day job; a grant expiring between Epic B's merge and Epic C's run would need a re-mint for no reason.

## 6. Can't-tell branches

| Where | Can't tell what | Does |
|---|---|---|
| Sweep: a key's re-verify finds a blob record with no row | whether the rows really hold this key's history | **stop** — keep the blob, log which records are missing, never delete, do not retry in a loop |
| Sweep: the blob will not decode during re-verify | what the blob contains | **stop** — keep it, log it |
| Sweep: a migrated key has no timestamp | when it migrated | **stop** deleting — stamp it now and let it age the full 30 days |
| Sweep: the key is not `channel_messages_*` or `messages_*` | whether a row equivalent exists | **stop** — out of scope, never considered |
| `VACUUM` fails, e.g. no temporary space | whether the file can be compacted | **proceeds**, logging the failure. Not fail-open on data: the deletes already happened and are correct, and `VACUUM` only affects file size. The next sweep retries it. |

No fail-open branch touches data. The one branch that proceeds affects file size only, and the deletes it follows are each individually verified.

## 7. Verification

- **Named command:** `flutter test test/storage/ test/screens/` plus `flutter analyze`
- **Acceptance bar:**
  - A key stamped older than 30 days, whose rows hold every blob record, loses its blob; the file shrinks after `VACUUM`.
  - A key stamped older than 30 days with **one** blob record missing from rows **keeps** its blob, and the refusal names the missing records. This gate must be proved able to fail.
  - A key stamped inside 30 days keeps its blob, including at 29 days, so the boundary is tested and not just the middle of each range.
  - A migrated key with no timestamp is stamped, not deleted.
  - `contacts`, `discovered_contacts` and `path_history_` keys are never considered, asserted by name.
  - An unmigrated history key keeps its blob.
  - **Every kept blob is byte-identical after `VACUUM`**, compared by hash before and after, with the unmigrated history keys asserted present by name. Row count unchanged. This is the owner's question answered as a test rather than a paragraph: the sweep must be shown to delete only what it selected, and `VACUUM` to add nothing to that set.
  - Run against a copy of a real database, reporting bytes reclaimed, and skipping loudly rather than passing when no database is supplied.

## 8. Done when

- No key migrated more than 30 days ago retains a message-history blob.
- The database file is measurably smaller, verified by reading the live file, not by trusting a log line.
- Row count is unchanged across the whole sweep.
- A key whose re-verify fails still has its blob, and said so.
- The Settings action reports a real before and after on the owner's install, on both platforms.

## 9. Decisions

Owner, 2026-10-22: *"X = 30, sweep once per launch, timestamps in separate blob, button reports refusals, agreed."* All four as recommended.

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | How long is X? | **30 days** | One full month of real use, and it matches the monthly granularity of the Play installs and crash reports the owner reads, so a migration problem gets a reporting cycle to surface in before the snapshot goes. 14 would have halved the double-storage window and also halved the time to notice. |
| 2 | When does the automatic sweep run? | **Once per launch**, after startup settles | Predictable, at most one `VACUUM` per launch, and it cannot fire mid-session while the app is in use. |
| 3 | Where do the timestamps live? | **A separate `__msgrows_migrated_at` blob** | `__msgrows_migrated` is read on every save and load through a cached hot path; reshaping it would risk that path and need its own migration. The timestamps are read only by the cold once-per-launch sweep. |
| 4 | If a key's re-verify fails, does the user hear about it? | **The manual action reports it. The automatic sweep stays log-only.** | The user pressed a button, so "cleared 12 keys, kept 1 that failed verification" is the honest result. Silence is how #952 went unnoticed. The automatic sweep has no one watching, so a log line is the right place for it. |

**30 days is a named constant, not a literal scattered through the sweep**, so changing it later is one edit and the tests can set it directly rather than manipulating clocks.

### Added 2026-10-23, after the mock-up review

| # | Question | Decision | Why |
|---|---|---|---|
| 5 | Does the manual action confirm before deleting? | **Yes, stating the scope**: how many copies, roughly how much space, how many messages are not affected, and that it cannot be undone. | It deletes and cannot be undone. See B1a; it needs a preview pass, and the mock-up's variants 8 to 10 are the approved shape. |
| 6 | "Compact" or "Clear Stale History"? | **Clear Stale History Now** | Owner's reason, and the better argument: the name generalises, so the same action can later cover clearing stale history for other reasons, such as the retention limit in #963. "Compact" describes `VACUUM`, which is an implementation detail. |
| 7 | Does an explicit press clear a key that has no timestamp yet? | **Yes.** The automatic sweep still refuses. | Found while building the preview. The "skip anything stamped this pass" guard exists so installing an update never deletes on sight, and it was being applied to the button too. Every install that migrated before #962 has no stamps, so the button would have reported "nothing to clear" against real reclaimable blobs. The owner's install was exactly that: 47 migrated keys, none stamped. `eligibleByAge` is now the one rule both paths share. |

## 10. Carried-in work

| Item | Goes to |
|---|---|
| Retention limit, capping days of history retained | #963 |
| Release-text disclosure for the first version carrying schema 2 | #953 |
| Whether rows need any backup or export story | not filed; raised on #943 and not asked for |
