# Initiative PLAN: client interop with upstream MeshCore 1.17.1/1.18.0

Plan of record for the client side of the upstream-1.18 world. Grounded in the 2026-10-17 investigation (three-surface contracts, population matrix, in-flight register — to be committed beside this plan as `INVESTIGATION.md`). This is one master plan carrying four features; each feature's epics derive from here and refine only what this leaves unspecified.

## At a glance

Upstream 1.18.0 introduces a companion CLI (local frame 66/29, remote TXT type 3 gated by contact-flag 0x10) and CLI-based WiFi config, moved its version code into the range the fork already spent (14 vs 14–22), and left the fork's binary surfaces (0xC0 config, `_sys`, caps bytes) untouched but newly overlapped. The client must (1) stop inferring capability from numbers both sides now use differently, (2) gain the CLI surfaces, (3) extend its existing Offband WiFi architecture (#837) without colliding with the in-flight firmware work (#365/#1448/#325), and (4) stay correct against four populations: stock 1.17.x, stock 1.18.0, Offband today (ver 22), Offband post-absorb.

**What you get when this is done:** a client that correctly identifies what it is talking to; a device CLI console for any stock-1.18+ or post-absorb device; remote CLI to permitted contacts with a per-contact permission toggle; WiFi configuration (including saved networks) that works on Offband today and is one adapter away from stock 1.18 devices; and a verified behavior matrix across all four populations.

## 1. Diagnosis

Done — [client#857](https://github.com/OffbandMesh/meshcore-client/issues/857) carries the full-read wire inventory; `INVESTIGATION.md` carries the three-surface contracts, the conflict matrix (`get wifi.pwd`: upstream cleartext readback vs fork write-only is the sharpest row), the population matrix, and the in-flight register. Key verified reuse: the client's `RepeaterCommandService` already implements the exact `XX|` prefix-correlation contract upstream extended to companions; the contact-write frame already carries the flags byte; the 0xC0 codec and WiFi write-planner stack are shipped and live.

## 2. Scope

Four features under this initiative. Firmware-side reconciliation (CommonCLI re-merge, `_sys` fate, 0xC0-vs-CLI convergence, VER_CODE strategy, prefs migration) is **out of scope** — tracked as dependencies D1–D3/D5, firmware's budget.

- **F1 — population discriminator & capability-gate rework.** Prerequisite for everything.
- **F2 — companion CLI, local.** Frame 66/29 console.
- **F3 — remote CLI.** Type 3 + contact permission 0x10.
- **F4 — WiFi.** The #837 scope (gating split, saved networks, apply flow) plus the stock-1.18 adapter if D4 says yes.

Out of scope, recorded: repeater WiFi via GUI (per #837); any firmware change; any use of fork frames toward stock devices.

## 3. Epics

### F1 — discriminator & gating (2 epics, ~6 tasks, 20–26 pts)
- **E1.1 Classifier + gate migration.** `DevicePopulation` classifier (frame shape 82/83/85 + ver code + caps + version-string dual format with the #691 `X-X` caveat); all caps parsing and the six ver-code gates route through it; channel-data bound 167→165; a documented seam where the firmware's durable marker (D1) replaces the interim signal. Fails closed: unknown population = stock-least-capability, no fork frames emitted.
- **E1.2 Conformance verification.** Fixture matrix (stock-1.17 / stock-1.18 / Offband-22 / malformed) through every gate; no UI change lands here.

### F2 — companion CLI, local (2 epics, ~6 tasks, 21–27 pts)
- **E2.1 Codec + service + console.** Frame 66/29 codec; shared correlation helper extracted from `RepeaterCommandService`; local command service (no mesh retries, frame-level timeout); console screen adapted from the `repeater_cli_screen` pattern; **mockup for your approval before the screen is built**; name-validation mirroring; 165-byte reply bound surfaced honestly (device truncates).
- **E2.2 Feature verification.** Against stock 1.18.0 (full vocabulary incl. wifi.* on a WiFi build) and an Offband device (console must not be offered pre-absorb).

### F3 — remote CLI (2 epics, ~6 tasks, 22–28 pts)
- **E3.1 Permission + send/receive.** Contact-flag 0x10 toggle (model/storage/contact UI, existing write frame); population-aware type selection (type 3 only to 1.18+/post-absorb peers, type 1 stays the server default); service generalization to companion targets; inbound type-3 accept + render (today warn-dropped); the no-permission UX — a type-3 send to an unpermitted companion produces *no reply at all* (it lands as a message on the target's app), so the console shows the timeout with that explanation and never auto-retries into silence.
- **E3.2 Feature verification.** Cross-population behavior matrix incl. 1.17 server reject and 1.17 companion silent-drop.

### F4 — WiFi (2 epics now, 1 decision-gated, ~5–9 tasks, 17–38 pts)
- **E4.1 Gating split + apply flow.** WiFi section on `0x01 || 0x08`, brokers/display on `0x01` alone (#375 corrected and absorbed here); apply-to-device over the existing 0xC0 write planner; status readout tolerant of both vocabularies.
- **E4.2 Saved networks.** Local store (new `lib/storage/` module), CRUD UI, apply-to-this-device; PSK-at-rest per D6. Mockups for your approval before screens.
- **E4.3 (gated on D4) Stock-1.18 adapter.** The same WiFi UI backed by wifi.* CLI over F2's service for stock devices; reboot-to-apply UX; `get wifi.pwd` output treated as a secret everywhere (masked, never logged, never stored device-side values).
- **Feature verification** rides E4.2 (and E4.3 if taken): Offband device via 0xC0; stock 1.18 via CLI if D4 yes.

## 4. Order and dependencies

F1 → F2 → (F3, F4 in either order). E4.3 additionally needs D4. Nothing here waits on the firmware absorb: F1's interim signal covers all four populations today, and the D1 marker swaps in at one seam. Cross-repo dependency register: D1 (VER_CODE/marker), D2 (0xC0 vs CLI on Offband, `get wifi.pwd` fate), D3 (`_sys` fate — affects docs/UX only on the client), D5 (#1448 sequencing — its cap 0x08 + ver 23 are what E4.1's gate consumes).

## 5. Grants and authorization

Proposed grant terms (basis: 8 epic PRs + this plan's PR; client repo, no device flashing):

```grant-terms
plan: OffbandMesh/meshcore-client — upstream-1180-interop
chain: E1.1 → E1.2 → E2.1 → E2.2 → E3.1 → E3.2 → E4.1 → E4.2 [→ E4.3 if D4]
verification per epic: flutter analyze + flutter test green; feature-verification epics additionally bench evidence recorded on the issue
merges: 10 (plan PR + 8–9 epic PRs), held to chain order
flash budget: 0 (no device flashing in this plan; bench flashes, if you want fresh images, are yours)
duration: 30 days
```

Push/PR asks will reach you as permission prompts (Remote Control is on); merges are yours — every PR arrives as a full link you can merge from the phone.

## 6. Can't-tell branches

| Branch | When the code can't confirm | It does |
|---|---|---|
| Population classifier | frame malformed / signals conflict | classifies **stock-least-capability**: no fork frames, no CLI offer; logs the evidence |
| CLI reply correlation | reply prefix matches nothing pending | surfaces to log + unmatched sink, never completes a different command (#532 behavior kept) |
| Remote CLI send | peer population unknown | refuses type 3, offers type 1 or nothing (servers only) |
| WiFi apply | device reports neither vocabulary | shows raw reply text, writes nothing further |
| Saved-network apply | password absent (D6 = prompt-at-apply) | stops and asks the user; never sends empty |

No fail-open branches; nothing proceeds on an unconfirmed condition.

## 7. Verification

Per-epic: `flutter analyze` + `flutter test` (fixtures from E1.2 reused everywhere). Feature-verification epics: live matrix against stock 1.17.1, stock 1.18.0, Offband current — devices and scheduling yours; results with evidence on the issues. 1.17.1 needs only the confirmation pass (wire-identical to 1.17.0 by full-read inspection).

## 8. Done when

All four features' verification epics closed on recorded evidence; the client behaves per the population matrix in `INVESTIGATION.md` §B3; no capability decision anywhere keys on a bare ver-code comparison; #857, #375, #138 resolved or re-scoped under this structure.

## 9. Your choices

| # | Decision | My recommendation (basis) |
|---|---|---|
| D1 | VER_CODE strategy (firmware) | explicit Offband marker in device-info; client never reads bare ver-code cross-population. Interim classifier makes this non-blocking. |
| D2 | Offband config mechanism post-absorb + `get wifi.pwd` fate | keep 0xC0 as the structured surface (client already speaks it, write-only pwd preserved); disable the cleartext readback in the absorb. |
| D3 | `_sys` fate | keep through the absorb; revisit retirement after F2's console ships and a parity audit exists. Client plan unaffected either way. |
| D4 | Configure stock-1.18 WiFi from the client? | yes — E4.3 is 2 tasks once F2 exists; it makes the client useful on stock hardware. Toggleable scope. |
| D5 | #1448 sequencing | proceed as in flight (contract settled on #365); the absorb reconciles. Named because it moves VER_CODE to 23. |
| D6 | Saved-network PSK at rest | platform secure storage, per-network opt-in; alternative is prompt-at-apply (safer, more friction). |
| — | Issue filing | on plan approval: initiative + 4 features + E-epics with lifecycle tasks, per the counted sizing (25–27 tasks, 87–119 pts + E4.3's 7–16). |

## 10. Carried-in work

#857 (diagnosis record — re-parent), #375 (corrected into E4.1), #138 (profiles import/apply — feeds E4.2), #795 (caplog-forward settings — consumer of F4, stays outside this plan), #529/#473 timeout work (already shipped in the service F2/F3 reuse).

---
Agent: GentleGlacier (session f0c92a36)
