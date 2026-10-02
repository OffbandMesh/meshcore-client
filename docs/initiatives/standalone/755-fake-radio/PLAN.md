# Feature PLAN: fake radio for automated testing in CI

| | |
|---|---|
| **Feature** | [#755](https://github.com/OffbandMesh/meshcore-client/issues/755) · Citadel `meshcore-open-6o3` |
| **Serves** | No parent Initiative; a standalone Feature. Absorbs #601 from Epic #598. Depends on OffbandMesh/meshcore-firmware#1318. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-02 |

## At a glance

- **What:** a software MeshCore companion radio, written in Dart, that the real client connects to with no hardware. It plays either **stock MeshCore** or **Offband** firmware, answers the same frames a real radio does from a seeded, deterministic state, and can play scripted faults.
- **Why now:** no test can take the client through a real connect, sync, send or settings change. Everything past "connected" is tested by the owner, by hand, on hardware. The #647 remote preset commands shipped with no on-air test for exactly this reason.
- **How it stays in sync:** the firmware publishes a machine-readable protocol manifest at every tag and merge (firmware#1318). The fake radio's profiles load it, and client CI fails when the client disagrees with it. Captured traces from a real Offband radio and a real stock radio check behavior.
- **How:** four Epics, in order:
  - A: the fake radio core, both profiles, the manifest check, in-process and over TCP;
  - B: messaging, radio settings, remote nodes, faults, and trace replay;
  - C: test suites that run in CI under both profiles, plus a runner for manual use;
  - D: integration testing, including capturing the real-radio traces.
- **Done when:**
  - Every PR's CI runs connect, sync, messaging and preset flows (including on a repeater, room server and sensor) against the fake radio, under both the stock and Offband profiles, with no hardware.
  - Client CI fails when the client's protocol constants disagree with the firmware's published manifest.
  - The owner can start the fake radio on his PC and connect the Windows app to it over TCP.

## 1. Diagnosis

Verified 2026-10-02 against `dev` @ `0fc407d4` and firmware `53951759`.

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Nothing past "connected" can be tested without a radio | `scanner_screen.dart:66` routes to the channel UI only on `connected`; #598 diagnosis | Connect, sync and messaging regressions reach users before anyone sees them |
| 2 | No test drives the protocol end to end | The only TCP tests are the transport (`tcp_transport_service_native_test.dart`, raw sockets) and `tcp_flow_test.dart`, which stubs `connectTcp` out entirely | The connector's handshake, sync and send logic (9,368 lines in `meshcore_connector.dart`) has no end-to-end test |
| 3 | The fake radio was planned, never built | #601 has no branch, comments or code | Nothing to build on but a plan |
| 4 | The connector already has an in-process seam | `handleFrameForTest` and `sendFrameOverrideForTest` (`meshcore_connector.dart:3112-3117`) | A fake radio can plug in with no sockets, so widget tests stay fast and deterministic |
| 5 | The TCP path needs no app changes, but uses serial framing | `connectTcp` (`meshcore_connector.dart:2295`); the transport wraps frames with `wrapUsbSerialTxFrame` (start `0x3c`) and decodes with `UsbSerialFrameDecoder` (start `0x3e`) (`tcp_transport_service_native.dart:11,92`) | The fake's TCP server must speak that framing |
| 6 | The handshake is a known, finite set | On connect the client sends `DEVICE_QUERY`, `APP_START`, `GET_CUSTOM_VARS`, battery, `GET_AUTO_ADD_CONFIG`, then contacts, channels and message sync (`meshcore_connector.dart:3592-3600`, `3712`); 53 frame builders, 34 response and push codes handled | The core can be built against a fixed list |
| 7 | Stock and Offband differ in what the radio reports | The client gates every Offband feature on the reported capability bytes (`_offbandCaps`, `_offbandCaps2`, `meshcore_connector.dart:370`) and the version code; the bits are defined in `OffbandConfigProtocol.h:275-299`; stock firmware reports none | A fake radio can play either by changing what it reports and which Offband commands it answers |
| 8 | The firmware publishes no machine-readable contract | The caps and `FIRMWARE_VER_CODE` registry is a prose comment table (firmware#514) | Today any copy of the protocol drifts silently; firmware#1318 fixes this at the source |
| 9 | Firmware version reporting is inconsistent | firmware#873 (`ver` vs `version` disagree), #958, #1277, #1311 | A test of the reported version catches this; firmware#1318 adds the firmware-side check |
| 10 | The firmware is the reference for every reply | `examples/companion_radio/MyMesh.cpp`, `handleCmdFrame` at line 1964; remote CLI in the shared `CommonCLI` | Each fake reply is copied from a named firmware function, not guessed |
| 11 | Remote-node presets are untested on air | #738 addendum: owner reviewed the screen, never applied a preset to a real node | The fake radio covers `set radio`, `tempradio` and `set path.hash.mode` in CI |
| 12 | No radio is on stock firmware today | Owner, 2026-10-02: one can be flashed | The stock trace capture needs one radio flashed to stock (section 5, Flash) |
| 13 | #598 scoped its bench out of CI | #598 body, owner 2026-08-24 | Reversed for the fake radio only (owner, 2026-10-02, logged on #598) |

## 2. Scope

**In:**
- A fake companion radio in Dart: frame codec, command dispatch, seeded state, deterministic clock.
- Two firmware profiles, stock and Offband, built from the firmware's published protocol manifests.
- A client CI check that the client's protocol constants match the manifest.
- Two ways to connect: in-process (through the connector's test seam) and a TCP loopback server.
- Messaging, acks, incoming messages, channels, radio settings, and repeater, room server and sensor admin (login and CLI) over the mesh.
- Scripted faults: dropped acks, error replies, disconnect mid-sync, slow replies.
- Trace replay: frames recorded from a real Offband radio and a real stock radio, which the fake must reproduce.
- Test suites in the default `flutter test`, so CI runs them on every PR.
- A standalone runner (`dart run tool/fake_radio.dart`) so the desktop app can connect over TCP.

**Out:**
- The firmware side of the manifest and the reported-version check: firmware#1318.
- BLE and USB serial fakes. TCP and in-process cover the protocol; the transports already have their own tests.
- Simulating RF, propagation or multi-hop routing. The fake radio reports paths and hops from its seed.
- The rest of #598: the `integration_test` harness (#602) and Win32 input injection (#603) stay on-demand.
- Any change to `lib/` beyond what a test needs to attach. The fake radio never ships in a release build.

## 3. Epics

Each Epic ends with a verification task and gets one PR. The first task reproduces the diagnosis as a failing test.

### Epic A: core, profiles and the manifest check (#756)

| Task | Pts |
|---|---|
| **A1 · Failing scenario test:** the real `MeshCoreConnector` connects and reaches `connected` with self info, contacts and channels loaded. Fails today: there is nothing to connect to. | 2 |
| **A2 · Core (absorbs #601):** frame codec, dispatch, seeded state (self info, device info, contacts, channels, queued messages, battery, custom vars, auto-add), deterministic clock. Every delay the fake produces (including B4's slow replies) runs on that clock, never wall time, so tests advance it with the test's fake clock. Every reply cites its firmware function. Unknown commands get the firmware's error reply. Unit tests per command. | 4 |
| **A3 · In-process and TCP adapters:** the same core behind `sendFrameOverrideForTest`/`handleFrameForTest`, and behind a loopback `ServerSocket` speaking the transport's serial framing (finding 5). | 3 |
| **A4 · Profiles from manifests:** the fake loads a `protocol-manifest.json` per profile. Offband: firmware version, version code and capability bits; answers the Offband commands. Stock: no capability bytes; rejects Offband commands as stock firmware does. Pinned copies are checked in under `test/` so CI runs offline. Until firmware#1318 publishes them, the pinned copies are generated once from the firmware source at the pinned tags, in the same format, and replaced by the published ones when they land. | 3 |
| **A5 · Manifest contract check:** a test that fails when `meshcore_protocol.dart` disagrees with the pinned Offband manifest (a command or response code, a capability bit, a version gate). Includes the reported-version fields. | 3 |
| **A6 · Epic verification:** A1 passes on both adapters and both profiles; same seed, same result over 20 runs; A5 fails on a deliberately wrong constant. | 1 |

### Epic B: messaging, settings, remote nodes, faults and replay (#757)

| Task | Pts |
|---|---|
| **B1 · Messaging:** direct and channel send (`SENT`, then `SEND_CONFIRMED` with a settable delay or drop), incoming messages through `MSG_WAITING` and `SYNC_NEXT_MESSAGE` in the V3 formats. | 4 |
| **B2 · Radio settings:** cmd 11, 12, 38 and 61 change the fake's state and show in the next `SELF_INFO`. | 2 |
| **B3 · Remote nodes:** seeded repeater, room server and sensor contacts; login success and failure; CLI replies for `get radio`, `set radio`, `tempradio`, `set path.hash.mode`, `set tx`, `ver` and `version`, copied from firmware `CommonCLI`. | 4 |
| **B4 · Scripted faults:** drop an ack, return an error, close the connection mid-sync, delay a reply. | 3 |
| **B5 · Trace capture and replay tooling:** a recorder that saves a real radio's frames from a client session to a fixture file, and a replay test that requires the fake to produce the same frames for the same requests and seed. Built and tested here against a recorded fake session; real-radio fixtures are captured in D1. | 4 |
| **B6 · Epic verification** | 1 |

### Epic C: CI suites and the manual runner (#758)

| Task | Pts |
|---|---|
| **C1 · Connector scenario suite, both profiles:** connect and sync; direct send, ack, retry and timeout; channel send; Companion preset apply (#647: cmd 11 radio params, cmd 12 TX power, cmd 61 path hash mode, checked in the fake's state and the next `SELF_INFO`); remote preset apply on a repeater, room server and sensor, including `tempradio` going last. Under the stock profile, also: no Offband feature is offered and no Offband command is sent. Runs in the default `flutter test`. | 4 |
| **C2 · Screen-level tests:** the channels screen and a chat screen, attached in-process to the fake radio; a composer send reaches the fake and the ack shows. | 4 |
| **C3 · Manual runner:** `dart run tool/fake_radio.dart --profile offband|stock --port 5000 --seed <file>`; seed file format documented. The Windows app connects to it by TCP. | 3 |
| **C4 · Release guard:** the fake radio lives only under `test/` and `tool/`; a test fails if anything under `lib/` imports it. | 2 |
| **C5 · Epic verification** | 1 |

### Epic D: integration testing (#759)

| Task | Pts |
|---|---|
| **D1 · Owner session:** the Windows app connected to the manual runner (both profiles); then one real Offband radio and one radio flashed to stock MeshCore, each connected once while B5's recorder runs. | 3 |
| **D2 · Real-radio conformance:** the D1 traces committed as fixtures; the replay test passes against both, or each difference is fixed or recorded. | 3 |
| **D3 · OUTCOMES.md** | 1 |

## 4. Order and dependencies

- A, B, C, D in that order. Each Epic's verification task blocks the next Epic (wired in Citadel).
- B builds on A's core and profiles; C uses everything in A and B; D needs all three.
- All Epics touch the same new files (`test/support/fake_radio/`, `tool/fake_radio.dart`), so they run in sequence. C2 is the only task that touches app screens, and only from tests.
- Merges wait until the end, so each Epic's branch is stacked on the one before.
- **firmware#1318** is not a blocker: A4 starts from pinned manifests generated from the firmware source, and switches to the published ones when #1318 lands. If #1318 changes the manifest format, A4's loader follows it.
- #598 keeps #599, #600, #602, #603 and #604. Its bench will use this fake radio, so #598 depends on this Feature.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Running Epics A to D in order without stopping between them: code, tests, builds, and one PR per Epic, stacked. | Canon: once the plan grant is minted, run the whole chain. |
| **Merges** | Held to the end of the Feature, in order A, B, C, D, after the owner's D1 session. | Canon. |
| **Epic verification** | Command mode: the merge hook runs `flutter test` on each PR's exact commit. | This Feature is test infrastructure; its own suites are the evidence. It also spares the owner a verify step per PR. |
| **Owner steps during the run** | None until D1. Before D1: pick the radio to flash to stock and mint its flash grant. At D1: the runner session and the two radio captures, in one sitting. | Canon: owner steps are one message, at the end. |
| **Stops** | A new decision; a fault I can't fix; a firmware reply I can't find a source for. | |
| **Flash** | One: before D1, the session flashes one radio the owner picks to a stock MeshCore companion release file, with `scripts/pio-flash` under a `dw-approve flash` for that exact device. | Finding 12. `pio-flash` flashes any firmware file, stock included (owner, 2026-10-02). No other device is touched. |

```grant-terms
{
  "epic_chain": [756, 757, 758, 759],
  "chain": true,
  "verification": { "mode": "command", "command": "flutter test" },
  "merge": { "budget": 4, "basis": "One PR per Epic: A (#756), B (#757), C (#758), D (#759: conformance fixtures and OUTCOMES.md)." },
  "flash": { "budget": 1, "basis": "One radio flashed to a stock MeshCore companion release for the D1 stock trace capture (finding 12)." },
  "reset": null,
  "expires_after_hours": 168
}
```

`expires_after_hours` basis: 55 points of work, roughly five to six working sessions, plus the owner's D1 session around his day job. 168 hours is the maximum.

## 6. Verification

- **Named command:** `flutter analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, the em-dash check, and `flutter test` (full suite, which includes the new suites). Every Epic PR shows the output.
- **Acceptance bar:** each finding in section 1 has a test that would have caught it. Most important: the handshake reaches `connected` under both profiles; the stock profile never sees an Offband feature or command; the manifest check fails on a wrong constant; a dropped ack is retried; a remote `tempradio` is sent last; a release build contains no fake radio code.
- **Owner requirement (#748):** every error message these flows show is tested present on failure and absent under ideal conditions.

## 7. Done when

- The default `flutter test`, and so every PR's CI, connects the real connector to the fake radio under both profiles and covers connect, sync, messaging, Companion presets and remote-node presets.
- Client CI fails when the client's protocol constants disagree with the pinned Offband manifest.
- The fake radio reproduces the captured traces from a real Offband radio and a real stock radio.
- The same fake radio runs from `tool/fake_radio.dart`, and the Windows app connects to it over TCP.
- Nothing under `lib/` imports the fake radio.
- The owner signs off D1, and `OUTCOMES.md` is approved.

## 8. Your choices

| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Where #601 lives | Move it into this Feature (A2); #598 depends on #755 | Leave it under #598 and build a second fake here | ⭐ A | **A** (2026-10-02) |
| 2 | Manual runner (C3) | In this Feature | Later, separately | ⭐ A (it's the "USB cables are tied up" case, and small once the TCP adapter exists) | **A** (2026-10-02) |
| 3 | Remote-node emulation (B3) | In this Feature | Later, separately | ⭐ A (it covers the #647 remote-preset gap in CI) | **A** (2026-10-02) |

## Decisions

| Date | Decision |
|---|---|
| 2026-10-02 | The fake radio runs in CI (reverses #598's "not in CI" for the fake radio only). |
| 2026-10-02 | Stock and Offband are emulated as separate profiles. |
| 2026-10-02 | The firmware publishes the protocol manifest at every tag and merge (firmware#1318); the fake radio consumes it, never a hand copy. |
| 2026-10-02 | Behavior is checked against captured traces from a real Offband radio and a radio flashed to stock. |
| 2026-10-02 | The session flashes the stock radio with `scripts/pio-flash`, which flashes stock files too (owner). |
| 2026-10-02 | Section 8: all three recommendations accepted. #601 moves under Epic A (#756); the manual runner and remote-node emulation are in scope. |

## 9. Carried-in work

| Item | Goes to |
|---|---|
| #601 (loopback fake radio, planned only) | A2 and A3 |
| #598 owner decision (not in CI) | Reversed for the fake radio only (2026-10-02, logged on #598) |
| #738 remote-preset test gap | C1 (in CI) |
| firmware#1318 (manifest, reported-version check) | Firmware repo; A4 and A5 consume it |
| firmware#514, #873 | Referenced by firmware#1318; firmware side |

## Alternatives considered but not chosen

- **Firmware CI builds the fake radio itself:** the fake is Dart code in the client repo; firmware CI builds C++. Firmware publishes the contract instead, and the client builds from it.
- **Hand-copied protocol constants in the fake:** drifts silently, the failure firmware#514 already documents.
- **`integration_test` on a Linux desktop runner in CI:** needs a display server and a full app build per run; the in-process adapter reaches the same screens from `flutter test`.
- **A Python or firmware-native simulator:** a second toolchain in CI, and it can't use the connector's in-process seam.
- **Running the real companion firmware on the host:** not investigated; it would mean building and maintaining a host port of the firmware, a much larger effort than this Feature.

When this plan merges, each Task gets a GitHub issue and a Citadel task, per canon.
