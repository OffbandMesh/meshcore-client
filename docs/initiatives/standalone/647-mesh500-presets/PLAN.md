# Feature PLAN: MESH 500 regional preset system

| | |
|---|---|
| **Feature** | [#647](https://github.com/OffbandMesh/meshcore-client/issues/647) · Citadel `meshcore-open-mli` |
| **Serves** | No parent Initiative; a standalone Feature. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-01 |

## At a glance

- **What:** one radio preset list in the app, with regional defaults plus local meshes (Arizona, SoCal, OKI, Philly). Pick a preset and apply it to a Companion, Observer, Repeater, Room Server or Sensor.
- **Why now:** our presets are a hardcoded list that can only change with an app release, it has no 500 kHz option, and several of its values are wrong. Regions change their settings: Philly has moved frequency, and OKI's isn't settled.
- **How:** four Epics, in order:
  - A: preset files in `config-profiles`;
  - B: the catalog and picker in the app, applied to Companion and Observer;
  - C: applying presets to remote nodes;
  - D: integration testing.
- **Done when:**
  - Editing a preset in `config-profiles` reaches users on their next refresh, with no app release (within about five minutes, GitHub's cache).
  - Every node type can apply a preset using stock firmware commands only.

## 1. Diagnosis

Verified 2026-09-23 to 2026-10-01. Full write-ups are on #647 and #722.

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Presets are a hardcoded Dart list with no update path | `lib/models/radio_settings.dart:63` (46 entries) | Any preset change needs an app release |
| 2 | Our coding rates are wrong for several regions | zjs81#72 dropped the CR column and set all to CR 5; Liam's registry (archived Oct 2025 by openhop, live today) has EU/UK Narrow CR8, Switzerland CR8, Portugal 433 CR6, Australia Narrow CR7 | Users picking those presets get the wrong CR |
| 3 | No preset can carry path hash | `RadioSettings` has no field (`radio_settings.dart:47-52`); Liam's list publishes it in bytes on 8 entries | Presets that need path hash leave it unset |
| 4 | Liam's list is the de facto community source | Stock app (`app.meshcore.nz`) fetches `api.meshcore.nz/api/v1/config` and bundles nothing; official map and config tools use it; CORS is open | It's the base we build on, with credit |
| 5 | Liam's list lacks entries our users need | Live list: 26 entries, none at 500 kHz, no Philly, OKI, Arizona or Russia | We need our own overlay |
| 6 | Stock firmware has no preset list | `meshcore-dev/MeshCore` `e9412598`: only one build default (869.618 / 62.5 / SF8) | Presets are a client concern; no firmware work needed |
| 7 | Every apply path exists in stock firmware | Companion cmd 11 + cmd 61; CLI `set radio`, `tempradio`, `set path.hash.mode` (upstream `CommonCLI.cpp`) | No Offband-specific codes |
| 8 | Path hash is published in bytes; firmware takes a zero-based mode | `sendFlood(..., path_hash_mode + 1)`; 2 bytes = mode 1 | A straight copy of the number puts the node off the mesh |
| 9 | `tempradio` retunes 2 s after replying; its timer overflows past ~35,791 minutes | `simple_repeater/MyMesh.cpp:1026-1034` | Must be sent last in a save, and the duration capped |
| 10 | The app has no admin path for Sensors | A Sensor contact only opens a chat (`contacts_screen.dart:981-987`); stock sensor firmware does run the shared CLI (`SensorMesh.cpp:450`) | Sensor apply needs an admin entry point |
| 11 | Room Servers already share the repeater admin screens | `contacts_screen.dart:1063` opens `RepeaterHubScreen` for room management | Repeater work covers Room Servers |

## 2. Scope

**In:**
- An Offband overlay preset file and a CI mirror of Liam's list in `OffbandMesh/config-profiles` (owner decision on #650 and #722).
- In the app: bundled snapshots of both, refresh, merge (ours over Liam's), last-good cache, a grouped picker with source labels, and credits.
- Applying presets to Companion, Observer, Repeater, Room Server and Sensor through stock commands only.
- A Temporary (`tempradio`) option for remote nodes (#662).

**Out:**
- Firmware changes.
- Changing any non-US preset beyond matching Liam's published values.
- Regulatory or legal advice.

## 3. Epics

Each Epic ends with a verification task and gets one PR. Issue numbers are already filed on board #2.

### Epic A: preset sources in config-profiles (#721)

Code lands in `OffbandMesh/config-profiles`.

| Task | Pts |
|---|---|
| **A1 · Overlay file + schema (#722):** OKI test, Philly (current values not yet known; to be found from a Philly Mesh source, or the chain stops), Arizona SF9/CR8, Russia, Off-Grid. Schema documents add, change and retire. Checked by a validation script. | 3 |
| **A2 · CI mirror of Liam's list (#723):** scheduled job. It runs A1's validation script on the fetched data **before** committing; if validation fails, the run fails and nothing is committed. Commits directly only on change. Checked by a manual run, a no-change rerun, and a simulated bad response. | 3 |
| **A3 · README credit (#724):** Liam Cottle / MeshCore, and the precedence rules. | 1 |
| **A4 · Epic verification (#725)** | 1 |

### Epic B: in-app catalog and picker, Companion and Observer (#726)

| Task | Pts |
|---|---|
| **B1 · Preset model (#727):** replaces the hardcoded list. Unit tests. | 3 |
| **B1b · Path hash field and bytes-to-mode conversion (#649):** tested conversion. | 2 |
| **B2 · Bundled snapshots, refresh, merge, last-good cache (#728, closes #648):** tests for offline, refresh, failure fallback, precedence, an edit with no release, and malformed entries. | 4 |
| **B3 · Grouped picker with source labels (#729):** widget test; preset match on load still works. | 3 |
| **B4 · Apply to Companion and Observer (#730):** cmd 11, TX power, cmd 61; client repeat preserved. Tests. | 3 |
| **B5 · Credits on About (#731)** | 1 |
| **B6 · Epic verification (#732)** | 1 |

### Epic C: apply to remote nodes (#733)

| Task | Pts |
|---|---|
| **C1 · Picker on the remote-node settings screen (#734):** Repeater and Room Server share it. | 3 |
| **C2 · Temporary checkbox (#662):** `tempradio`, sent last, duration capped. Tests. | 3 |
| **C3 · Path hash via `set path.hash.mode` (#735):** tests. | 2 |
| **C5 · Sensor admin entry point (new issue at merge):** log in to a Sensor and reach the same settings screen. Depends on owner choice 1. | 3 |
| **C4 · Epic verification (#736)** | 1 |

### Epic D: integration testing (#737)

| Task | Pts |
|---|---|
| **D1 · End-to-end on every node type (#738):** owner hardware. | 3 |
| **D2 · OUTCOMES.md (#739)** | 1 |

## 4. Order and dependencies

- A, B, C, D in that order. Each Epic's verification task blocks the next Epic (wired in Citadel).
- B needs A's file format. C reuses B's catalog and conversion. D needs all three.
- Within B: B1, B1b, B2, B3 and B4 all touch `radio_settings.dart` and `settings_screen.dart`, so they run in sequence.
- Within C: C1, C2, C3 and C5 all touch `repeater_settings_screen.dart` (C5 also `contacts_screen.dart`), so they run in sequence.
- Because merges wait until the end, C's branch is stacked on B's, and D's on C's. A fix found in B during D's hardware testing gets rebased up through C.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Running Epics B, C and D in order without stopping between them: code, tests, builds, and one PR per Epic as it finishes. | The owner asked for the chain to run unattended unless a decision or fault needs him. |
| **Merges** | Deferred to the end of the chain, in order B, C, D, after the owner's hardware review in D. | Owner direction: merges come at the end. |
| **Epic verification** | Owner mode. My verification task (analyze, full test suite, format, em-dash check, Windows and APK builds) closes each Epic and lets the chain continue. The owner's approval of each PR happens at the end, before merge. | Hardware testing is the owner's gate; consolidating it at D avoids pausing the chain. |
| **Owner steps during the run** | None, unless a stop below fires. At the end: hardware review (D1), then approve the PRs. | |
| **Stops** | A new decision; a fault I can't fix; Philly's current values if no public source; Epic A's PR, because it's in `config-profiles` and outside this grant (needs a separate `dw-approve merge`). | Grants cover this repo only. |
| **Flash** | None. | No firmware is flashed. |

```grant-terms
{
  "epic_chain": [726, 733, 737],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 3, "basis": "One PR per Epic in this repo: B (#726), C (#733), D (#737, OUTCOMES.md). Epic A merges in config-profiles, outside this grant." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

`expires_after_hours` basis: A plus B plus C is roughly four to five working sessions of build time, plus the owner's end-of-chain hardware review. 168 hours (the maximum) leaves room for his day job.

## 6. Verification

- **Named command (this repo):** `flutter analyze` with CI flags, `dart format --set-exit-if-changed`, the em-dash check, and `flutter test` (full suite). Every Epic PR shows the output.
- **Named command (config-profiles):** the A1 validation script over both files, plus one mirror job run.
- **Acceptance bar:** each finding in section 1 has a test that would have caught it. Most important: wrong CR values, path hash bytes-to-mode, `tempradio` ordering and cap, and an overlay edit reaching the app with no release.

## 7. Done when

- The picker shows Liam's presets plus ours, grouped, with sources and credits, and works offline.
- An overlay edit in `config-profiles` reaches the app on its next refresh with no new build, within about five minutes (GitHub's raw-file cache, #452).
- Companion, Observer, Repeater, Room Server and Sensor can each apply a preset with stock commands, including path hash and the Temporary option.
- The owner signs off D1, and `OUTCOMES.md` is approved.

## 8. Your choices

| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Sensors have no admin path in the app today | Add one (C5): log in, reuse the repeater settings screen | Drop Sensor from this Feature and file it separately | ⭐ A | |
| 2 | When does your hardware testing happen? | Once, at Epic D, before any merge; the chain runs straight through. Risk: a hardware fault in B is found only after C is built on it, so the rework is bigger. | After each Epic, before the next starts. Catches faults earlier, but the chain pauses for you each time. | ⭐ A (your stated direction) | |

## 9. Carried-in work

| Item | Goes to |
|---|---|
| #648 (hardcoded list, no update path) | B2 |
| #649 (preset path hash) | B1b |
| #662 (Temporary checkbox) | C2 |
| #661 (OKI stopgap, closed) | A1 |
| #650 (source decision, closed) | Decisions recorded; this plan implements them |
| Sensor admin path (finding 10) | C5, new issue when this plan merges |
