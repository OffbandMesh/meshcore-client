# Observer Settings — Offband Meshcore **client** design

- **Feature:** OffbandMesh/meshcore-client#63 · **Planning epic:** #64
- **Firmware counterpart:** OffbandMesh/meshcore-firmware#142 (impl) + #143 (agreed wire contract)
- **Scope:** the **client** side only. Firmware-owned wire constants are **TBD-from-firmware** (RedCreek).
- **Status:** revised after Gemini adversarial review (2026-06-21, verdict *reconsider* → all findings addressed below, §11) → owner sign-off (AGREE) → implementation.

Legend: **[F]** Fact (code/contract) · **[A]** Assumption · **[U]** Uncertainty (needs decision/firmware input).

---

## 1. Context
When connected to an **Observer** device (Offband firmware variant bridging LoRa↔MQTT over WiFi), configure its **MQTT brokers, WiFi, display, region** from client forms instead of `_sys` text commands. Firmware decision (locked, #143 "option-2"): one Offband-owned `config` companion command (sub-type set/get/view + paginated broker list), key/value flat settings, contacts-style broker pagination, `_sys` fallback, capability-gated, device-NVS source of truth, secrets write-only/redacted. **[F]**

**Client today:** zero MQTT/WiFi/Observer support. Shell ready: `settings_shell.dart` (responsive master-detail); categories built in `settings_screen.dart:_categories()` (~L72–131); device read via connector getters, written via `setX()`/`sendFrame()` + refresh; long-press menu pattern exists (`contacts_screen.dart` `onLongPress` + `onSecondaryTapUp`). **[F]**

## 2. Config contract (from #143)
- `wifi`: `ssid`, `pwd`(**WO**), `enabled`
- `mqtt` global: `iata`, `status_int`
- `mqtt.broker.<0–9>`: `enabled`, `url`, `port`, `transport`(tcp/tls/wss), `auth_type`(none/basic/jwt), `username`, `password`(**WO**), `topic_prefix`, `iata_override`, `jwt_aud`, `jwt_refresh`, `jwt_owner`, `jwt_email`, `ca_cert`, `jwt_token`(**WO**)
- `display`: `always_on`, `rotation`(0/180)

Secrets never returned by GET. Pool = 10 slots. **[F]**

## 3. Phasing (revised — de-risk pagination early)
- **Phase 1 — flat settings** (`wifi`/`display`/`iata`/`status_int`) **+ a non-UI broker-list GET in the integration test (T6)** to prove the multi-frame `START→SLOT×N→END` decode — the riskiest path — before any Phase-2 UI is built. (Review finding #4.)
- **Phase 2 — MQTT broker pool UI** (list + editor), building on the now-proven pagination decode.

## 4. Connector layer
### 4a. `ObserverConfigClient` codec (new `lib/connector/observer_config_client.dart`)
Owns encode/decode of the `config` command only, so UI/models never touch wire bytes. **[A → justified by review #1: a binary, externally-owned, still-TBD wire contract is exactly when an Adapter earns its keep; pragmatic exception to "no helper until 3+ places".]**
- `setFlat(key, value)` / `getFlat(key)` — flat key/value.
- `getBrokers()` → decode the paginated stream into `BrokerConfig[]` (secrets absent).
- `setBrokerField(slot, field, value)` — single field (firmware contract is field-at-a-time).
- `brokerOp(slot, BrokerOp)` — enable/disable/clear.

**Secrets:** the codec only emits a secret key when the model's intent is `set`/`clear`, never for `unchanged` (see §5) — prevents the blank-field wipe footgun. **[F, review #1]**

**TBD-from-firmware (gate coding, not design) [U]:** config CMD code + sub-type bytes; broker-slot frame layout + enum encodings; pagination framing.

### 4b. Capability gating (revised — two-factor, review #3)
`bool get supportsObserverConfig` is true iff **BOTH**: (1) `FIRMWARE_VER_CODE ≥` the firmware gate, **AND** (2) a **`WIFI_OBSERVER_SUPPORT` capability flag** in the `CMD_DEVICE_QUERY` response is set. Version code alone cannot tell a build with `wifi_observer` compiled out from one with it — gating on version only yields a dead category. The category is shown and `config` is sent only when both hold; on reconnect the flag is re-read before the category renders (no stale-handshake flicker). **[F, review #3]** → **firmware-coordination item (§10):** confirm/define the capability flag with RedCreek.

### 4c. State + refresh
Connector holds parsed `ObserverConfig?` + a getter + `refreshObserverConfig()`. A failed refresh sets a **stale flag** the UI surfaces (never silently shows stale data). `notifyListeners()` on update. **[F, review #6/#7]**

## 5. Data models (new `lib/models/observer_config.dart`)
`ObserverConfig { WifiConfig wifi; MqttGlobalConfig mqtt; List<BrokerConfig> brokers; DisplayConfig display; }`, `MqttGlobalConfig`, `DisplayConfig`, enums `BrokerTransport`/`BrokerAuthType`/`BrokerOp`.

**Secret fields use a three-state intent type** (not a bare `String?`): `SecretField { unchanged | clear | set(value) }`. GET yields `unchanged`; the codec sends nothing for `unchanged`, an empty value for `clear`, the value for `set`. This makes "leave / clear / replace" explicit end-to-end. **[F, review #1]**

**Storage: none** — device NVS is the source of truth; the client reads/writes the device, no `lib/storage/` copy. **[F]**

## 6. UI (new `lib/screens/settings/observer_settings_view.dart`)
### 6a. Category
One `SettingsCategory(title:"Observer", builder:_observerPane)` added to `_categories()`, **conditionally** on `connector.supportsObserverConfig`. **[F]**

### 6b. Save model — ONE rule for the whole pane (review #5)
**Every control edits staged local state; nothing is sent to the device until an explicit "Save".** Toggles flip visually on tap but only transmit (`setFlat`) on Save, alongside all other pending changes. Consistent, predictable; no "did my toggle apply?" ambiguity. A per-pane Save (✓/disk) + Refresh live in the app bar. **[F, review #5]**

### 6c. WiFi (P1)
SSID (text), Password (**three-state secret** — renders `•••• (set, hidden)`; untouched ⇒ not sent; clear button ⇒ `(cleared)` ⇒ sends empty; typing ⇒ `set`), Enabled (toggle). Status line (`get wifi.status`) + refresh. Save sends only changed fields. **[F, review #1/#5]**

### 6d. Display + Region/status (P1)
`always_on`, `rotation` (segmented), `iata`, `status_int` (10–3600) — all staged, sent on Save.

### 6e. MQTT brokers (P2) — owner UX
- **List shows all 10 slots** (resource constraint visible); empty slots greyed with a "Configure"/＋ affordance, populated slots show url + enabled badge. **[F, review #8]**
- **Tap** → broker editor (app-bar Refresh + Save).
- **Long-press / desktop right-click** → menu **Enable / Disable / Edit / Clear** → `brokerOp()` / open editor. Reuses the contacts pattern. **[F]**

### 6f. Broker editor (P2)
Fields per `BrokerConfig`; `transport`/`auth_type` dropdowns; auth fields conditional; secrets three-state. **Save = send all changed fields**, then **on ANY field failure, immediately auto-`getBrokers()` and render the device's actual (possibly partial) state + a clear "save was partial" error** — never leave the UI asserting a state the device doesn't hold. **[F, review #2 — mitigates the non-atomic field-at-a-time contract.]**

## 7. State / disconnect / errors
- **In-flight edits on disconnect:** preserve the user's staged input, **disable Save**, show a "reconnect to save" banner; restore on reconnect — never silently clear the form. **[F, review #7]**
- **Error visibility (SAFELANE §6):** every `config` round-trip is `await`ed in `try/catch`; failures surface a **persistent** (dismissible) SnackBar/banner in the pane **and** `_appDebugLogService.error(…)`. No fire-and-forget sends, no silent refresh no-ops. **[F, review #6]**

## 8. File-overlap analysis (File-Convergence Rule)
| Area | Files |
|---|---|
| Models | `lib/models/observer_config.dart` *(new)* |
| Codec | `lib/connector/observer_config_client.dart` *(new)* + `lib/connector/meshcore_connector.dart` *(hook + capability + state)* |
| UI | `lib/screens/settings/observer_settings_view.dart` *(new)* + `lib/screens/settings_screen.dart` *(registration)* |

**Serialize** tasks touching `meshcore_connector.dart` and `settings_screen.dart`; new files parallelize. **[F]**

## 9. Task breakdown (1–3 files each)
**Phase 1** (dep: firmware F1 constants + capability flag):
- **T1** models *(new)*.
- **T2** `ObserverConfigClient` flat set/get **+ `getBrokers()` decode** *(new + connector hook)*. dep: T1, firmware constants.
- **T3** two-factor capability gating *(connector)*. dep: T2.
- **T4** Observer category + WiFi pane (staged-save model) *(settings_screen.dart + observer_settings_view.dart)*. dep: T2, T3.
- **T5** Display + Region/status panes *(observer_settings_view.dart)*. dep: T4.
- **T6 integration test** — Phase-1 round-trip **+ a non-UI `getBrokers()` decode** against a firmware F1 build (proves pagination early). dep: T4, T5.

**Phase 2** (dep: T6):
- **T7** broker list UI (all-10-slots) *(observer_settings_view.dart)*. dep: T6.
- **T8** broker editor + staged save + partial-failure auto-refresh *(observer_settings_view.dart)*. dep: T7.
- **T9** long-press Enable/Disable/Edit/Clear *(observer_settings_view.dart)*. dep: T7.
- **T10 integration test** — Phase-2 round-trip. dep: T8, T9.

## 10. Firmware-owned constants + coordination (RedCreek / #142)
TBD constants: (1) `config` CMD code + sub-type bytes; (2) broker-slot frame layout + enum encodings; (3) `app_target_ver` gate. **Coordination items raised by the review:** (4) a **`WIFI_OBSERVER_SUPPORT` capability flag** in `CMD_DEVICE_QUERY` (version code alone is insufficient — review #3); (5) confirm the broker SET is field-at-a-time (no transactional `setBroker`) so the client must own the partial-failure mitigation (review #2). (6) a Phase-1 build to test against. Client coding holds until (1)–(3) land.

## 11. Review responses (Gemini gemini-2.5-pro, 2026-06-21 — standards#145: fix or justify, no silent dismissals)
| # | Finding | Sev | Disposition |
|---|---|---|---|
| 1 | Write-only secret UX ambiguous → accidental wipe | BLOCKER | **Fixed** — three-state `SecretField` (§5) + three-state input UX (§6c/§6f); codec never sends `unchanged` (§4a). |
| 2 | Field-at-a-time broker save → partial/corrupt state | BLOCKER | **Fixed (client mitigation)** — on any field failure, auto-`getBrokers()` + render actual state + partial-error (§6f). **Coordinating** firmware transactional-set feasibility (§10.5). |
| 3 | Version-code-only capability gating → dead UI | MAJOR | **Fixed** — two-factor: version + `WIFI_OBSERVER_SUPPORT` flag (§4b); re-read on reconnect. **Coordinating** the flag with firmware (§10.4). |
| 4 | Phasing defers riskiest (pagination) to P2 | MAJOR | **Fixed** — minimal non-UI `getBrokers()` decode pulled into P1 integration test T6 (§3, §9). |
| 5 | Inconsistent immediate-vs-explicit save | MAJOR | **Fixed** — single rule: stage locally, commit on explicit per-pane Save (§6b). |
| — | In-flight edits lost on disconnect | (ans 7) | **Fixed** — preserve input, disable Save, restore on reconnect (§7). |
| — | Broker list all-10 vs populated | (ans 8) | **Fixed** — show all 10, empty slots distinct (§6e). |
| — | Silent-failure surfaces | (ans 6) | **Fixed** — awaited try/catch + persistent surfacing + stale-flag on refresh fail (§4c/§7). |

Verdict was *reconsider*; all BLOCKER/MAJOR findings are now addressed in-design above.
