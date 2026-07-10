# Observer Config (client) — Phase 1 plan **v2 (REVISED, security-first)**

- **Epic:** OffbandMesh/meshcore-client **#64** · **Feature:** #63 · **Firmware contract:** F1 #160 (delivered, `OffbandConfigProtocol.h`)
- **Date:** 2026-06-22 · **Standards:** @96da86c · **Status:** awaiting Ben AGREE
- **v1 was rejected.** v1 self-validated my own code ("MET, analyze-clean") and had no threat model. A Gemini adversarial review then found **2 BLOCKERs in the very layers v1 graded "MET"** plus 2 MAJOR / 2 MINOR (`docs/llm-consultations/2026-06-22-observer-phase1-security-review.md`). This version treats the existing commits as an **UNTRUSTED DRAFT**, builds a threat model first, turns every finding into a sized fixing task with the adversarial test **written first**, and gates a device test behind a *re-review*, not behind my word.

---

## 1. Threat model (this is what v1 was missing)

| | |
|---|---|
| **Assets** | Write-only secrets (MQTT/JWT credentials, `wifi.pwd`, `ca_cert`); client availability/stability; config integrity. |
| **Adversary** | A malicious or compromised observer device. It controls **every inbound byte and the order of frames** over BLE/USB/TCP. |
| **Capabilities** | Send arbitrary/malformed frames; omit `END`; stream unbounded `BROKER_KV`; spoof codes/sub-types; race/duplicate frames; supply garbage for numeric/enum fields; out-of-range slot indices. |
| **Trust boundary** | The transport. **Everything inbound is untrusted.** `observer_config_client.parse()` + `BrokerListDecoder` + `ObserverConfigService` ARE the parsing trust boundary — they must be hostile-input-safe, not just contract-happy. |
| **Non-goals (this phase)** | Transport encryption/auth (owned by the BLE/companion layer); broker enable/clear (firmware gap). |

---

## 2. Gemini findings → fixing task (nothing dropped)

| # | Sev | Finding | Fixed by |
|---|-----|---------|----------|
| 1 | **BLOCKER** | Race: "one request in flight" assumed, not enforced; shared `receivedFrames` + order-correlation → wrong `Completer` completes | **S1** (single-flight queue) + **A2** (proves it) |
| 2 | **BLOCKER** | DoS: `BrokerListDecoder` grows unbounded on a no-`END` `BROKER_KV` flood → OOM | **C1** (decoder bounds) + **A1** (proves it) |
| 3 | MAJOR | Plan has no threat model / adversarial tests | **TM** (§1) + **A1/A2** (this plan) |
| 4 | MAJOR | `offband_caps` byte-82 offset unverified; short-frame robustness | **N1** (guard + device-verify) |
| 5 | MINOR | Broker slot index not range-checked (`slot: 200` accepted) | **C1** (validate `< brokerSlotCount`) |
| 6 | MINOR | Secret **keys** leak into error strings (`SET wifi.pwd failed…`) | **S1** (redact secret keys) |

---

## 3. Revised sized tasks (1–3 files; **adversarial tests written FIRST**)

| ID | Title | Files | Depends on |
|----|-------|-------|------------|
| **TM** | Threat model + this revised plan (AGREE gate) | *(this doc)* | — |
| **A1** | **Adversarial codec test suite** — malformed/short frames, missing NUL, OOB slot, non-numeric numerics, no-`END`/unbounded `BROKER_KV`, duplicate `START`. Must FAIL on current code first. | `test/observer_config_client_test.dart` *(new)* | TM |
| **C1** | Harden codec: validate slot `< brokerSlotCount` in `parse`; bound `BrokerListDecoder` (cap entries at 10, drop OOB, cap fields/slot). Fixes #2, #5. | `lib/connector/observer_config_client.dart` | A1 |
| **A2** | **Service test suite** — overlapping `refresh()`/`setFlat()` must serialize (no cross-talk); secret-key redaction; timeout releases decoder. Must FAIL first. | `test/observer_config_service_test.dart` *(new)* | TM |
| **S1** | Service single-flight queue/mutex (fixes #1) + redact secret keys in errors (fixes #6). | `lib/services/observer_config_service.dart` | A2, C1 |
| **M1** | Models (existing draft; minor). | `lib/models/observer_config.dart` | TM |
| **N1** | Connector cap-read: guard short frames; **verify byte-82 offset against real device-info frames** (device sub-gate). Fixes #4. | `lib/connector/meshcore_connector.dart` | TM |
| **P1** | Provider wiring. | `lib/main.dart` | S1 |
| **U1** | UI + capability-gated category. | `lib/screens/settings/observer_settings_view.dart`, `lib/screens/settings_screen.dart` | S1, P1 |
| **G1** | **Re-run Gemini adversarial review** on hardened code — must clear both BLOCKERs. | *(gate)* | A1, A2, C1, S1 |
| **G2** | **Human device test on a live observer node (Ben).** Integration gate. | *(gate)* | G1, N1, U1 |
| **PR** | ONE PR at completion + Ben approval → merge. | *(gate)* | G2 |

**File-overlap:** every source file is owned by exactly one task (codec→C1, service→S1, connector→N1, main→P1, UI→U1, models→M1; tests are new files). No intra-epic conflicts.

**Dependency chain**
```
TM(threat model + AGREE)
 ├─ A1 ─ C1 ─┐
 ├─ A2 ──────┴─ S1 ─ P1 ─ U1 ─┐
 ├─ M1                         │
 └─ N1 (device-verify offset) ─┤
                               └─ G1 (re-Gemini, clears BLOCKERs) ─ G2 (Ben device test) ─ PR
```

---

## 4. Gates (in order, none skippable)
1. **AGREE** — Ben approves THIS plan before any code (the gate I skipped in v1).
2. One claimed Citadel task per ID; each is a child issue of #64 on board #2.
3. **Adversarial tests (A1/A2) written and failing before the fix; passing after.**
4. **G1 re-review** must clear both BLOCKERs.
5. **G2 — Ben device test** is the integration gate. I cannot clear it.
6. **ONE PR** at completion, after G2, with Ben's explicit approval.

---

## 5. The guardrails I skipped → the exact vulnerability each would have caught

This is the honest accounting. Every one of these was a guardrail I bypassed, and every bypass let a specific defect through:

| Guardrail I skipped | What it would have caught |
|---|---|
| **AGREE on a plan w/ threat model before code** | Forces modeling the adversary before writing an untrusted-input parser → the **DoS** and **race** are designed out, not discovered later. |
| **Adversarial / Gemini review before publishing** | Gemini caught **both BLOCKERs in one pass**. I self-validated and graded the buggy codec + service "MET." |
| **TDD / adversarial tests first** | A malformed-frame + unbounded-stream test would have **failed immediately** — instead the OOB slot and unbounded decoder shipped *analyze-clean*. |
| **Human-test gate before PR** | I put code that **crashes under normal use** (the race) and **crashes on a hostile device** (the DoS) onto the merge track, and asked you to merge it. |
| **"analyze-clean ≠ tested/secure"** | I treated a clean static analysis as done. Two crash-class bugs passed it without a whimper. |
| **Treat device input as untrusted** | The whole bug class — I wrote a parser for attacker-controlled bytes as if the bytes were trusted. |

---

## 6. Status of the existing commits (`1983ed9`, `12f5f97`, PR #67)
**Untrusted draft — not a basis to test.** They are analyze-clean but contain both BLOCKERs. They are useful as a starting point for M1/U1/etc., but each file is rewritten/hardened under its task and must pass A1/A2 + G1 before G2. PR #67 should be pulled down (mid-epic, pre-test, contains the BLOCKERs).

**Nothing proceeds until Ben AGREEs this v2.**
