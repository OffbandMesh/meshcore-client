# Investigation: client↔firmware contracts for upstream 1.17.1/1.18.0 interop

Status: investigation, not a plan. Every claim is from a read of the named source this session (2026-10-17). Firmware tags read in the firmware repo's tag space; client read at `C:\Dev\meshcore-open` HEAD.

---

## A. The three management surfaces — as-is contracts

### A1. Upstream 1.18.0 CLI (new)

**Transports.**
- *Local:* `CMD_RUN_CLI_COMMAND` (66) → `RESP_CODE_CLI_REPLY` (29). Request `[66][ascii command]` (len ≥ 3); reply `[29][ascii reply]`, reply ≤ 165 bytes (`reply_buf[166]`). No request id — correlation only via the optional prefix (below). `[verified: MyMesh.cpp handleCmdFrame at companion-v1.18.0]`
- *Remote:* `TXT_TYPE_CLI_COMMAND` (3) inside `CMD_SEND_TXT_MSG` / `PAYLOAD_TYPE_TXT_MSG`. No ACK. Receiving **companion** executes only if contact flags bit **0x10** (`isRemoteCLIAllowed`) is set, else the text queues to the app as a message; reply returns as a normal `TXT_TYPE_CLI_DATA` message, +600 ms (`CLI_REPLY_DELAY_MILLIS`), timestamp uniquified. Receiving **repeater/room server**: type 3 treated exactly like CLI_DATA (room server: admin only). `[verified: BaseChatMesh.cpp, MyMesh.cpp (companion), simple_room_server/MyMesh.cpp at the tag]`
- *Serial:* same `handleCommand` behind the rescue CLI; RP2040 WiFi builds also serve it on USB serial.

**Correlation.** Optional 3-char prefix: a command whose `[2] == '|'` (len > 4) has its first 3 chars reflected at the reply start. Upstream-origin: present in 1.17.0 server roles, extended to the companion in 1.18.0 `[verified: grep at companion-v1.17.0 + 1.18.0]`. **The client already implements exactly this** (`RepeaterCommandService._nextPrefixToken` → `XX|`; reply match on `[2]=='|'`) with computed timeouts, 5 retries, sole-pending fallback for short commands, and 2-minute late-reply attribution `[verified: repeater_command_service.dart, whole file]`.

**Vocabulary.** (a) `CommonRadioPrefs` — strings preserved verbatim from the old CommonCLI: `get/set radio`, `freq`, `af`, `dutycycle`, `int.thresh`, `cad`, `radio.rxgain`, `tx`, `rxdelay`, `agc.reset.interval`, `path.hash.mode`, `multi.acks`, `txdelay`, `direct.txdelay` `[verified: CommonRadioPrefs.cpp whole file]`. (b) Companion built-ins: `set/get name` (rejects `[ ] \ : , ? *`), `set pin`, `reboot`, `poweroff`/`shutdown`, `board`, `ver`, `get/set tz.offset`, `power`, `gps diag`. (c) `wifi.*` under `ENABLE_WIFI_INTERFACE`: `set/get wifi.ssid`, `set wifi.pwd`, **`get wifi.pwd` → cleartext password**, `set wifi.clear`, `set/get wifi.enabled`, `get wifi.status` (`> connected|disconnected`), `get wifi.ip`; ssid/pwd/enabled apply at reboot. (d) Variant hook `board.handleCommand` (FEM `get/set radio.fem.*` on FEM boards only).

**Error semantics.** Text only: `"Unknown command"` appended after the (reflected) prefix; `"Error, ..."`/`"ERROR: ..."` strings per command. **No structured error codes, no ERR frame** — a client cannot distinguish failure classes without string matching.

**Gating.** No capability advert. Local CLI exists on every v14+ stock companion; `wifi.*` only on `ENABLE_WIFI_INTERFACE` builds — a client discovers absence only by the `Unknown command` reply.

### A2. Offband 0xC0 config (`CMD_OFFBAND_CONFIG`) — your way, in flight

**Frame contract** (client codec mirrors byte-for-byte): `[0xC0][op][ascii payload NUL]`. Ops `SET 0x00`, `GET 0x01`, `VIEW 0x02`, `BROKERS 0x03`. Responses `[0xC0][sub]`: `ACK 0x00`, `ERR 0x01` (text starts `ERROR`), `VALUE 0x02` (`key = value`), brokers stream `0x10/0x11/0x12`, view stream `0x20/0x21/0x22` `[verified: observer_config_client.dart:89-130]`.

**Keys/semantics.** `wifi.ssid` / `wifi.pwd` / `wifi.enabled` (+ `mqtt.*`, display) — **same key names as upstream's CLI** but: `wifi.pwd` is **write-only** (GET errors), storage is NVS (`"wifi"` ns), gating is `ver_code ≥ 14 AND cap bit` — observer `0x01`; companion `0x08` being delivered right now by [firmware#1448](https://github.com/OffbandMesh/meshcore-firmware/issues/1448) (BUILD in flight, BrownWaterfall) with a **planned VER_CODE bump 22→23**. The op/key/error contract for companions was settled on [firmware#365](https://github.com/OffbandMesh/meshcore-firmware/issues/365) (comments of 2026-07-24, per client#375's banner). TCP `:5000` exposure: standing owner-accepted risk, nothing required of the client.

**Client stack on this contract (shipped + in flight):** pure codec (`observer_config_client.dart`), device-agnostic `ConfigSourceService`, `ConfigProfile` with typed `wifi` section, write planner (orders `wifi.enabled` last, `wifi.pwd` is a danger key), `wifi.status` state model (`boot/cliRescue/awaitingSetup/staConnecting/staConnected/staFailed`), settings UI with write-only pwd field. Feature umbrella: [client#837](https://github.com/OffbandMesh/meshcore-client/issues/837) (companion + observer/companion upgrade + **saved networks** — the genuinely new work), children-to-be #375, #138, #795.

### A3. Observer `_sys` channel CLI

Channel-message CLI on the `_sys` system channel over the normal app link — the observer build's **only** management surface (no serial console). Allowlisted verbs `get/set/mqtt/wifi/display`; **rejects** `reboot`/`ota.`/`fs.`/`format`/shell metacharacters. Grammar: `<ns> <verb>` actions + `get|set <ns>.<field>`. Secrets write-only. `get wifi.status` kept as a backward-compat alias of `wifi status` `[verified: docs/observer-cli-commands.md at firmware-base]`. Behind it sits the fork's **+988-line CommonCLI delta** with ~30 fork-only command families (caplog, display, led, safety, telemetry, fem on/off, ota, cmd_poll, resetreason, hangtest…) `[verified: diff + string-set diff companion-v1.17.0 → firmware-base]`.

---

## B. Overlap and conflict matrix

### B1. Same command string, different contract

| Command | Upstream 1.18 CLI | Offband 0xC0 | Offband `_sys` |
|---|---|---|---|
| `get wifi.ssid` | returns SSID | VALUE reply, same meaning | returns SSID |
| `get wifi.pwd` | **cleartext password** | **ERR (write-only)** | **blocked (write-only)** |
| `set wifi.pwd …` | OK, reboot to apply | ACK, reboot/STA-retry | OK, reboot/STA-retry |
| wifi enable/disable | `set wifi.enabled 1/0` | `set wifi.enabled …` key | `wifi enable` / `wifi disable` verb |
| `get wifi.status` | `> connected/disconnected` | n/a (status via model) | alias of `wifi status` (rich STA state) |
| `reboot`/`poweroff` | **supported** | n/a | **deliberately rejected** |
| radio cmds (`set tx`, `get radio`, …) | CommonRadioPrefs | n/a | CommonCLI (same strings) + fork families |

The `get wifi.pwd` row is the sharpest: if the absorb lands upstream's companion `handleCommand` unmodified on Offband builds, the same string that today safely errors becomes a cleartext credential readback — including over the remote type-3 path (contact-permission-gated) and the unauthenticated TCP transport. That is a **firmware absorb decision**, not a client one; the client spec must assume either answer is possible per population.

### B2. Mechanism-level divergence

- **Gating:** upstream = implicit (build flags, probe-by-command); Offband = explicit cap bits (`0x01`/`0x08`, per-unit, never model/version). Client currently gates everything the Offband way.
- **Storage:** upstream JSON prefs (`wifi` object, new in 1.18) vs Offband NVS `"wifi"` ns — a device-side migration problem in the absorb; client-invisible except through behavior drift.
- **VER_CODE:** upstream spent 14 on "CLI exists"; the fork spent 14 on "0xC0 exists" and is heading to 23 (#1448) while upstream is at 14 and climbing. Every fork bump deepens the collision. The number is unusable cross-population without a discriminator.
- **Defaults:** upstream `wifi_enabled = 1` in code at the tag (a commit subject says 0 — code wins) with empty-SSID guard; fork policy flag also defaults enabled. Incidentally aligned.

### B3. Population behavior matrix (client's view)

| Function | stock 1.17.x | stock 1.18.0 | Offband today (ver 22) | Offband post-absorb |
|---|---|---|---|---|
| device-info caps bytes | absent (82 B) | absent (82 B) | present (83/85 B) | present (decision: layout survives) |
| frame 66 local CLI | — (unknown cmd) | **yes** | — | yes (inherits) |
| type 3 remote | servers: log+ignore · companions: **silent drop** | yes (0x10-gated) | silent drop | yes (0x10-gated) |
| 0xC0 config | — | — | observer `0x01`; companion `0x08` landing (#1448) | **decision** |
| `_sys` CLI | — | — | observers | **decision** |
| wifi via CLI `wifi.*` | — | ENABLE_WIFI_INTERFACE builds | — | **decision** (readback!) |

---

## C. Per-feature client contract specs, gaps, counted sizing

Sizing counts real tasks at your 3–5-pt standard, from the reuse verified above. These moved **down** from my rev-3 guess for CLI (console + correlation machinery already exist) and the hidden cost surfaced in F4 (reconciliation).

### F1 — population discriminator & gate rework (prerequisite for everything)

**Spec:** one `isOffbandFirmware`/population classifier consuming: device-info length (82 vs 83/85), ver code, caps bytes, firmware-version string (`<ob>-<mc>` dual format; release images show `X-X`, firmware#691). All capability gates (6 ver-code sites, caps parsing, GPS presence gate) and all new CLI gating route through it. Interim signal = frame shape; swap seam for the firmware's durable marker when the VER_CODE ruling lands (decision D1).
**Gaps:** none blocking the interim; durable signal blocked on D1.
**Tasks (6, ~20–26 pts):** classifier + population fixtures (4); caps-parse rerouting (3); ver-gate migration + channel-data 167→165 bound (4); version-string parser w/ #691 handling (3); durable-marker seam + contract doc (3); conformance sweep across 4 populations (4).

### F2 — companion CLI, local (frame 66)

**Spec:** codec `[66][prefix?][cmd]` / `[29][prefix?][reply]`; prefix `XX|` (shared with repeater service); reply ≤165; errors are strings (`Unknown command`, `Error…`) — client classifies by prefix-stripped text, nothing structured to parse; no pagination (long output truncates device-side); vocabulary per A1 (radio set, built-ins, wifi.* when built in, variant FEM). Offered **only** when F1 says stock ≥14 (today) — Offband devices gain it at absorb.
**Gaps (upstream contract):** no structured errors; no ERR frame distinct from text; no way to enumerate supported commands (probe-only); >165 replies silently cut.
**Tasks (6, ~21–27 pts):** codec + tests (3); local command service (frame round-trip, no mesh retries; extract shared prefix/correlation helper out of `RepeaterCommandService`) (4); console screen adapted from `repeater_cli_screen` pattern for the local device (5); gating + entry point via F1 (3); name-validation mirroring + command-reference strings/l10n (3); population tests incl. Offband-must-not-offer (3).

### F3 — remote CLI (type 3 + contact permission)

**Spec:** send = `CMD_SEND_TXT_MSG` with `txt_type 3` (client's builder already parameterizes type for CLI sends); permission = contact flags bit 0x10, **written with the existing add/update-contact frame — the flags byte is already in the client's builder** `[verified: meshcore_protocol.dart:1277]`; replies arrive as CLI_DATA with the reflected prefix → `RepeaterCommandService` machinery applies nearly wholesale (timeouts per #529's computed windows + the now-source-verified 600 ms device hold). Population rule: type 3 only to peers F1 places at 1.18+/post-absorb; type 1 remains the server default everywhere.
**Gaps (upstream contract):** a companion **without** 0x10 gives the sender *no* reply and no error — the command just lands as a message on the target's app; indistinguishable from packet loss on the sending side. The spec must define the client UX for that (timeout + explanatory state, never retry-spam). Room-server: type 3 is admin-gated like CLI_DATA — same existing behavior.
**Tasks (6, ~22–28 pts):** flags-0x10 model/getter/copyWith + contact-UI toggle + write-path test (4); population-aware type selection in the send path (4); service generalization companion-vs-repeater targets (4); inbound type-3 accept + render (today warn-dropped) + storage flag (4); no-permission UX per gap above (3); cross-population behavior tests (4).

### F4 — WiFi: the reconciliation (the real $5M corner)

This is not "add a WiFi screen". Three mechanisms now exist for the same keys; your architecture (#365→#1448, #837) is mid-flight on one of them; upstream shipped another; `_sys` carries a third grammar. **Client work splits into (a) what proceeds regardless and (b) what is blocked on firmware decisions D2–D4.**

**(a) Proceeds regardless (~5 tasks, 17–22 pts):** gating split per #837 — WiFi on `0x01||0x08`, brokers/display on `0x01` (3); #375 body correction + re-parent under #837 (part of same task); saved-networks local store (new `lib/storage/` module; PSK-at-rest decision D6 shapes it) (4+4: store + CRUD UI); apply-to-device over the existing 0xC0 write planner (4); status-readout tolerance for both vocabularies (fork rich states vs upstream connected/disconnected) (3).
**(b) Blocked on decisions:** any use of upstream `wifi.*` CLI for stock-1.18 devices (D4) ≈ +2 tasks (7–9 pts: CLI-backed adapter behind the same UI, reboot-to-apply UX); any change to the 0xC0 path if the absorb alters it (D2); `get wifi.pwd` handling if readback survives anywhere (mask, never log, never store from device) — spec'd now, applied per D2's outcome.

### Sizing rollup (client side, counted)

| Feature | Tasks | Points | Confidence |
|---|---|---|---|
| F1 discriminator | 6 | 20–26 | high — surfaces enumerated |
| F2 local CLI | 6 | 21–27 | high — reuse verified |
| F3 remote CLI | 6 | 22–28 | high — service reuse verified |
| F4 WiFi (a) unblocked | 5 | 17–22 | medium — PSK-at-rest open |
| F4 WiFi (b) decision-gated | 2–4 | 7–16 | low until D2/D4 |
| **Total** | **25–27** | **87–119** | |

Per-feature verification (bench against stock 1.17.1, stock 1.18.0, Offband current) is counted inside the test tasks above; device time is yours to schedule. **Not counted:** all firmware-side reconciliation (the CommonCLI 988-line re-merge, `_sys` fate, 0xC0-vs-CLI convergence, prefs-storage migration, VER_CODE strategy) — firmware's budget, not the client's, listed here only as dependencies.

---

## D. In-flight register (what the merge must not run over)

**Firmware:** #1448 (0xC0 on companion, cap 0x08, ver 22→23 — BUILD in flight); #365 (contract parent, `board:in-progress`); #325 (serial+WiFi coexistence, live credential-change); #295 chain (#300 shared config backend **done**, #301–#307 open — GUI config #305 names client screens); CLI-surface issues the upstream CLI refactor collides with: #891/#892 (CLI surface integrity + verification toolchain), #657 (led/display dispatch gaps on 1.17.0 base), #871 (serial writers vs framed protocol), #873 (ver/version identity), #893 (wifi CLI 20–25 s round-trip), #359 (unbounded sprintf in reply formatters — upstream's `reply_buf[166]` meets fork formatters here).
**Client:** #837 (WiFi feature, owner-scoped), #375 (needs 0x02→0x08 correction), #138, #795; CLI pain already filed: #529/#473 (timeout formula — the 600 ms hold is now source-verified), #531/#532/#528/#589 (reply matching/late replies — already fixed in the service), #83 (bulk config read).

## E. Decision points (yours; the client spec consumes the answers)

1. **D1 — VER_CODE strategy** for the fork vs upstream's 14+ (and #1448's planned 23): re-map, re-base, or an explicit Offband marker. Decides F1's durable signal. (Firmware decision; client input filed on client#857.)
2. **D2 — Offband companion config mechanism post-absorb:** 0xC0 (#1448 path), upstream `wifi.*` CLI, or both — and specifically whether `get wifi.pwd` readback is disabled in the absorb. Decides F4(b) and the security posture row in B1.
3. **D3 — `_sys` fate post-absorb:** retire into frame-66 CLI, adapt (keep allowlist, same grammar), or keep as-is for observers. Decides whether the client's `_sys` documentation/UX assumptions persist.
4. **D4 — does the client configure STOCK 1.18 WiFi** (via upstream CLI) or stay Offband-only? Scope call on #837.
5. **D5 — sequencing:** does #1448 land on the 1.17.0 base as planned (ver 23) before the absorb, or wait for D1? (Named because it moves the collision; the call is yours and BrownWaterfall's work is in flight.)
6. **D6 — saved-network PSK at rest** on the phone (restated from #837).

Agent: GentleGlacier (session f0c92a36)
