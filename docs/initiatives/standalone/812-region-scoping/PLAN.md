# Feature PLAN: region scoping (client): Discover Regions + channel Set Region Scope

| | |
|---|---|
| **Feature** | [#812](https://github.com/OffbandMesh/meshcore-client/issues/812) · Citadel `meshcore-open-e0l` |
| **Serves** | No parent Initiative; a standalone Feature. Pulls "Set Region Scope" out of the #651 channel-menu parity bundle. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-07 |

## At a glance
- **What:** a **Discover Regions** action that asks a reachable repeater which regions it floods, and a per-channel **Set Region Scope** action (stock channel-menu parity) that makes that channel's outgoing messages ride the chosen region's flood scope.
- **Why:** stock MeshCore has both; Offband has neither. Owner-directed 2026-10-06.
- **How:** entirely client-side against current stock-parity firmware. No firmware change. Four Epics in order: A protocol/transport, B Discover Regions, C channel Set Region Scope, D hardware integration test.
- **Done when:** the owner can discover regions from his repeater, set a channel's region, send on that channel scoped to the region, and confirm on hardware; the feature is hidden on firmware that doesn't support it.

## 1. Diagnosis
Verified against firmware `C:\Dev\meshcore-firmware` and client `dev`, 2026-10-06/07. Full cited contract on #817.

| # | Finding | Evidence |
|---|---|---|
| 1 | Client has no region capability; only raw repeater-CLI passthrough | `repeater_cli_screen.dart` region commands; no region model/UI in `lib/` |
| 2 | **Discover Regions = an ANON request**, not control-data | `ANON_REQ_TYPE_REGIONS 0x01` via `CMD_SEND_ANON_REQ 57`; repeater `handleAnonRegionsReq` replies region names; reply to app as `PUSH_CODE_BINARY_RESPONSE 0x8C` `[0x8C,0,tag4,clock4,CSV names]` `[simple_repeater MyMesh.cpp:58,150-166,599; companion MyMesh.cpp:3114-3141,1201-1211; RegionMap.cpp:318-346]` |
| 3 | Region names are public; key is derivable | transport key = first 16B of `SHA256("#"+name)`; `$`-prefixed private regions are not name-derivable `[RegionMap.cpp:173-188; TransportKeyStore.cpp:44-47; TransportKeyStore.h:8]` |
| 4 | Scope-set is exposed over the companion | `CMD_SET_FLOOD_SCOPE_KEY 54` (sub-0 set 16B key / sub-1 unscoped), `CMD_SET_DEFAULT_FLOOD_SCOPE 63`, `CMD_GET_DEFAULT_FLOOD_SCOPE 64`, `RESP 28` `[companion MyMesh.cpp:3512-3547]` |
| 5 | No per-channel scope in firmware | `companion MyMesh.cpp:896 "// TODO: have per-channel send_scope"`; send applies one `send_scope` override or the node default |
| 6 | Client implements none of it; v8+ | highest client command 61; `appProtocolVersion 4`; client already gates by `firmwareVerCode` (`firmwareSupportsPktHash` >= 22) `[meshcore_protocol.dart]` |

## 2. Scope
**In:**
- Protocol: anon regions request + 0x8C reply parse; flood-scope cmd 54/63/64 + RESP 28; name->key (SHA256) + on-air code (HMAC); firmware-version gate.
- Discover Regions: query a chosen repeater, parse the CSV region names, present a list.
- Channel scope: per-channel region stored client-side; channel-menu "Set Region Scope"; and the **client-orchestrated per-send** apply (set `send_scope` via cmd 54 sub-0 with the channel's SHA256 key immediately before each channel send, reset after).
- Optional node default scope via cmd 63/64.

**Out:**
- Firmware changes of any kind (per-channel firmware scope, finding 5, is a firmware TODO the owner sequences separately).
- `$`-prefixed private regions (keys not name-derivable).
- RF/IATA region settings (#503) and geofencing: different concern.
- Administering a repeater's region map (that is the existing repeater CLI).

## 3. Epics
Each Epic ends with a verification task and gets one PR. The first task reproduces the diagnosis as a failing test.

### Epic A: protocol + transport layer (#813)
| Task | Pts |
|---|---|
| **A1 · Region model + key derivation:** NEW `lib/models/region.dart`, NEW `lib/helpers/region_key.dart` (transportKeyForName = first 16B of SHA256("#"+name); on-air code HMAC). Unit tests incl. a known vector and wildcard. | 2 |
| **A2 · Frames + version gate:** `lib/connector/meshcore_protocol.dart` constants (cmd 54/63/64, resp 28, push 0x8C), builders (anon regions req type 0x01, set-scope-key, default-scope set/get), parsers (resp 28, 0x8C CSV), `firmwareSupportsRegionScope(verCode)`. Unit tests. | 3 |
| **A3 · Connector wiring:** `lib/connector/meshcore_connector.dart`: `discoverRegions()`, set/clear channel send scope, set/get default scope, 0x8C + resp 28 handling (tag-matched), exposed via stream/callback. | 3 |
| **A4 · Epic verification:** protocol unit tests pass; frames round-trip against a real radio on benign paths. | 1 |

### Epic B: Discover Regions (#814)
| Task | Pts |
|---|---|
| **B1 · Discovery service:** NEW `lib/services/region_discovery_service.dart`: target a repeater, send, collect/parse/dedupe 0x8C replies; timeout, empty, parse-error all surfaced. Unit tests with a fake connector. | 3 |
| **B2 · Discover Regions UI:** list screen/dialog (source node, SNR), entry point, l10n. | 3 |
| **B3 · Epic verification:** discover against rpt-01 returns its regions; empty/timeout surfaces. | 1 |

### Epic C: channel Set Region Scope (#815)
| Task | Pts |
|---|---|
| **C1 · Per-channel scope store:** NEW `lib/storage/channel_region_scope_store.dart` (device-key scoped, channel->region) + model + tests. | 3 |
| **C2 · Channel-menu action + picker:** `lib/screens/channel_chat_screen.dart` overflow item "Set Region Scope" + picker (sourced from B), writes the store, l10n. | 3 |
| **C3 · Send-path scoping:** `lib/connector/meshcore_connector.dart` channel send: apply send_scope (cmd 54 sub-0, SHA256) before send, reset after; optional node default (cmd 63). | 3 |
| **C4 · Epic verification:** a scoped channel send applies the right key on the wire. | 1 |

### Epic D: integration testing (#816)
| Task | Pts |
|---|---|
| **D1 · Owner hardware session:** discover from rpt-01 -> set a channel's region -> send -> confirm flood-scoped; verify the feature is hidden on non-supporting firmware. | 2 |
| **D2 · OUTCOMES.md** | 1 |

## 4. Order and dependencies
- A, B, C, D in order; each Epic's verification blocks the next (wired in Citadel).
- **File overlap:** only `lib/connector/meshcore_connector.dart` is shared (A3 and C3) -> Epic C depends on Epic A. No other cross-task file collisions.
- Merges held to the end of the Feature, stacked, so each Epic branch is on the one before.
- Fail-closed branches (standards#677): firmware ver < gate -> feature hidden, never send region frames; discovery empty/malformed -> surface, never show empty as success; discovery timeout -> surface + retry, never hang; channel scoped but firmware unsupported -> block the send with a clear error, never send unscoped; cmd 54 ERR before a send -> abort + surface. No fail-open branches.

## 5. Grants and authorization
| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Running Epics A to D in order without stopping between them: code, tests, builds, one PR per Epic, stacked. | Canon: once the plan grant is minted, run the whole chain. |
| **Merges** | Held to the end of the Feature, in order A, B, C, D, after the owner's D1 hardware session. | Canon. |
| **Epic verification** | Command mode: the merge hook runs `flutter test` on each PR's exact commit; the owner's D1 hardware session is the Feature-level gate before the end merges. | Minimizes owner per-PR steps; the real on-air proof is D1. |
| **Owner steps during the run** | None until D1 (the hardware session, one sitting). | Canon: owner steps are one message, at the end. |
| **Stops** | A new decision; a firmware reply I can't cite; a fault I can't fix. | |
| **Flash** | None (client-only; owner tests via a build, the session flashes nothing). | |

```grant-terms
{
  "epic_chain": [813, 814, 815, 816],
  "chain": true,
  "verification": { "mode": "command", "command": "flutter test" },
  "merge": { "budget": 4, "basis": "One PR per Epic: #813 protocol, #814 Discover Regions, #815 channel Set Region Scope, #816 integration test + OUTCOMES.md." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```
`expires_after_hours` basis: ~32 points across four Epics at interactive pace around the owner's day job; 168h is the maximum.

## 6. Verification
- **Named commands** on every Epic PR: `flutter analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, the em-dash guard, `flutter test`.
- **Acceptance:** key derivation matches a firmware vector; discovery parses a real repeater's region CSV; a scoped channel send puts the right transport key on the wire; the feature is hidden on firmware below the gate; every surfaced error is tested present-on-failure and absent-when-ideal (#748).
- **D1 hardware session** proves discover -> scope -> send end to end; the owner signs off.

## 7. Done when
- Discover Regions lists the owner's repeater's regions over BLE/USB.
- A channel can be scoped to a discovered region; its sends ride that region's flood scope, confirmed on hardware.
- The feature is hidden/disabled on firmware that doesn't support it.
- `OUTCOMES.md` is approved.

## 8. Your choices
| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Epic verification mode | Command (`flutter test` per PR; D1 is the on-air gate) | Owner `dw-approve verify` per Epic PR | A (fewer steps for you; D1 is the real proof) | |
| 2 | Node default scope (cmd 63) | Include as an option in C | Channels only, skip default | A (cheap, matches firmware) | |

## Decisions
| Date | Decision |
|---|---|
| 2026-10-06 | Build region scoping client-side; stock parity: Discover Regions + channel Set Region Scope. |
| 2026-10-07 | Diagnosis (#817) accepted: discovery = anon request; scope via flood-scope commands; key = SHA256("#"+name). |
| 2026-10-07 | Channel scope is client-orchestrated per-send (cmd 54 before each channel send): the only path at parity with stock firmware until stock exposes per-channel scope. |

## Alternatives considered but not chosen
- **Control-data (PAYLOAD_TYPE_CONTROL) for discovery:** that is node discovery (`CTL_TYPE_NODE_DISCOVER 0x80/0x90`), not regions; regions use the anon-request path.
- **Per-channel firmware scope:** firmware TODO (finding 5); would be firmware work the owner sequences, not this client Feature.
- **Reading the stock client (Liam's) source for the discovery format:** unavailable; the firmware is the authoritative contract and fully specifies it.

When this plan merges, each Task gets a GitHub issue and a Citadel task, per canon.
