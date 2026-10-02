# Feature PLAN: fake radio for automated testing in CI

| | |
|---|---|
| **Feature** | [#755](https://github.com/OffbandMesh/meshcore-client/issues/755) · Citadel `meshcore-open-6o3` |
| **Serves** | No parent Initiative; a standalone Feature. Absorbs #601 from Epic #598. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-02 |

## At a glance

- **What:** a software MeshCore companion radio, written in Dart, that the real client connects to with no hardware. It answers the same frames a radio does, from a seeded, deterministic state, and can play scripted faults.
- **Why now:** no test can take the client through a real connect, sync, send or settings change. Everything past "connected" is tested by the owner, by hand, on hardware. The #647 remote preset commands shipped with no on-air test for exactly this reason.
- **How:** four Epics, in order:
  - A: the fake radio core and handshake, reachable in-process and over TCP;
  - B: messaging, radio settings, remote nodes and faults;
  - C: test suites that run in CI, plus a runner for manual use;
  - D: integration testing.
- **Done when:**
  - Every PR's CI runs connect, sync, messaging and preset flows (including on a repeater, room server and sensor) against the fake radio, with no hardware.
  - The owner can start the fake radio on his PC and connect the Windows app to it over TCP.

## 1. Diagnosis

Verified 2026-10-02 against `dev` @ `0fc407d4` and firmware `53951759`.

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Nothing past "connected" can be tested without a radio | `scanner_screen.dart:66` routes to the channel UI only on `connected`; #598 diagnosis | Connect, sync and messaging regressions reach users before anyone sees them |
| 2 | No test drives the protocol end to end | The only TCP tests are the transport (`tcp_transport_service_native_test.dart`, raw sockets) and `tcp_flow_test.dart`, which stubs `connectTcp` out entirely | The connector's handshake, sync and send logic (9,368 lines in `meshcore_connector.dart`) has no end-to-end test |
| 3 | The fake radio was planned, never built | #601 has no branch, comments or code | Nothing to build on but a plan |
| 4 | The connector already has an in-process seam | `handleFrameForTest` and `sendFrameOverrideForTest` (`meshcore_connector.dart:3112-3117`), used by 2 test files | A fake radio can plug in with no sockets, so widget tests stay fast and deterministic |
| 5 | The TCP path needs no app changes | `connectTcp` (`meshcore_connector.dart:2295`) frames over `TcpTransportService`; a loopback server works (the transport test binds one) | The same fake radio can serve the real desktop app |
| 6 | The handshake is a known, finite set | On connect the client sends `DEVICE_QUERY`, `APP_START`, `GET_CUSTOM_VARS`, battery, `GET_AUTO_ADD_CONFIG`, then contacts, channels and message sync (`meshcore_connector.dart:3592-3600`, `3712`); 53 frame builders, 34 response and push codes handled | The core can be built against a fixed list |
| 7 | The firmware is the reference for every reply | `examples/companion_radio/MyMesh.cpp`, `handleCmdFrame` at line 1964; remote CLI in the shared `CommonCLI` | Each fake reply is copied from a named firmware function, not guessed |
| 8 | Remote-node presets are untested on air | #738 addendum: owner reviewed the screen, never applied a preset to a real node | The fake radio can cover `set radio`, `tempradio` and `set path.hash.mode` replies in CI |
| 9 | #598 scoped its bench out of CI | #598 body, owner 2026-08-24 | Reversed for the fake radio only (owner, 2026-10-02, logged on #598) |

## 2. Scope

**In:**
- A fake companion radio in Dart: frame codec, command dispatch, seeded state, deterministic clock.
- Two ways to connect: in-process (through the connector's test seam) and a TCP loopback server.
- Messaging, acks, incoming messages, channels, radio settings, and repeater, room server and sensor admin (login and CLI) over the mesh.
- Scripted faults: dropped acks, error replies, disconnect mid-sync, slow replies.
- Test suites in the default `flutter test` run, so CI runs them on every PR.
- A standalone runner (`dart run tool/fake_radio.dart`) so the desktop app can connect over TCP.

**Out:**
- BLE and USB serial fakes. TCP and in-process cover the protocol; the transports already have their own tests.
- Simulating RF, propagation or multi-hop routing. The fake radio reports paths and hops from its seed; it does not model a mesh.
- The rest of #598: the `integration_test` harness (#602) and Win32 input injection (#603) stay on-demand.
- Any change to `lib/` beyond what a test needs to attach. The fake radio never ships in a release build.

## 3. Epics

Each Epic ends with a verification task and gets one PR. The first task reproduces the diagnosis as a failing test.

### Epic A: fake radio core and handshake (#756)

| Task | Pts |
|---|---|
| **A1 · Failing scenario test:** the real `MeshCoreConnector` connects and reaches `connected` with self info, contacts and channels loaded. Fails today: there is nothing to connect to. | 2 |
| **A2 · Core (absorbs #601):** frame codec, dispatch, seeded state (self info, device info, contacts, channels, queued messages, battery, custom vars, auto-add), deterministic clock. Every delay the fake radio produces (including B4's slow replies) runs on that clock, never on wall time, so tests advance it with the test's fake clock. Every reply cites its firmware function. Unknown commands get the firmware's error reply. Unit tests per command. | 4 |
| **A3 · In-process and TCP adapters:** the same core behind `sendFrameOverrideForTest`/`handleFrameForTest`, and behind a loopback `ServerSocket`. The TCP side must speak the transport's serial framing, not raw frames: the client wraps each frame with `wrapUsbSerialTxFrame` (start byte `0x3c`) and decodes replies with `UsbSerialFrameDecoder` (start byte `0x3e`) (`usb_serial_frame_codec.dart`, `tcp_transport_service_native.dart:11,92`). | 3 |
| **A4 · Epic verification:** A1 passes on both adapters; same seed, same result over 20 runs. | 1 |

### Epic B: messaging, settings, remote nodes and faults (#757)

| Task | Pts |
|---|---|
| **B1 · Messaging:** direct and channel send (`SENT`, then `SEND_CONFIRMED` with a settable delay or drop), incoming messages through `MSG_WAITING` and `SYNC_NEXT_MESSAGE` in the V3 formats. | 4 |
| **B2 · Radio settings:** cmd 11, 12, 38 and 61 change the fake's state and show in the next `SELF_INFO`. | 2 |
| **B3 · Remote nodes:** seeded repeater, room server and sensor contacts; login success and failure; CLI replies for `get radio`, `set radio`, `tempradio`, `set path.hash.mode` and `set tx`, copied from firmware `CommonCLI`. | 4 |
| **B4 · Scripted faults:** drop an ack, return an error, close the connection mid-sync, delay a reply. | 3 |
| **B5 · Epic verification** | 1 |

### Epic C: CI suites and the manual runner (#758)

| Task | Pts |
|---|---|
| **C1 · Connector scenario suite:** connect and sync; direct send, ack, retry and timeout; channel send; Companion preset apply (#647: cmd 11 radio params, cmd 12 TX power, cmd 61 path hash mode, checked in the fake's state and the next `SELF_INFO`); remote preset apply on a repeater, room server and sensor, including `tempradio` going last. Runs in the default `flutter test`. | 4 |
| **C2 · Screen-level tests:** the channels screen and a chat screen, attached in-process to the fake radio; a composer send reaches the fake and the ack shows. | 4 |
| **C3 · Manual runner:** `dart run tool/fake_radio.dart --port 5000 --seed <file>`; seed file format documented. The Windows app connects to it by TCP. | 3 |
| **C4 · Release guard:** the fake radio lives only under `test/` and `tool/`; a test fails if anything under `lib/` imports it. | 2 |
| **C5 · Epic verification** | 1 |

### Epic D: integration testing (#759)

| Task | Pts |
|---|---|
| **D1 · Owner run:** the Windows app connected to the manual runner; the CI run on the Epic C PR with the new suites. | 2 |
| **D2 · OUTCOMES.md** | 1 |

## 4. Order and dependencies

- A, B, C, D in that order. Each Epic's verification task blocks the next Epic (wired in Citadel).
- B builds on A's core; C uses everything in A and B; D needs all three.
- All Epics touch the same new files (`test/support/fake_radio/`, `tool/fake_radio.dart`), so they run in sequence. C2 is the only task that touches app screens, and only from tests.
- Merges wait until the end, so each Epic's branch is stacked on the one before.
- #598 keeps #599, #600, #602, #603 and #604. Its bench will use this fake radio, so #598 depends on this Feature.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Running Epics A to D in order without stopping between them: code, tests, builds, and one PR per Epic, stacked. | Canon: once the plan grant is minted, run the whole chain. |
| **Merges** | Held to the end of the Feature, in order A, B, C, D, after the owner's D1 run. | Canon. |
| **Epic verification** | Command mode: the merge hook runs `flutter test` on each PR's exact commit. | This Feature is test infrastructure; its own suites are the evidence. It also spares the owner a verify step per PR. |
| **Owner steps during the run** | None. At the end: D1, then mint merges. | |
| **Stops** | A new decision; a fault I can't fix; a firmware reply I can't find a source for. | |
| **Flash** | None. | No device is touched. |

```grant-terms
{
  "epic_chain": [756, 757, 758, 759],
  "chain": true,
  "verification": { "mode": "command", "command": "flutter test" },
  "merge": { "budget": 4, "basis": "One PR per Epic: A (#756), B (#757), C (#758), D (#759, OUTCOMES.md)." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

`expires_after_hours` basis: 41 points of work, roughly four to five working sessions, plus the owner's D1 run around his day job. 168 hours is the maximum.

## 6. Verification

- **Named command:** `flutter analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed`, the em-dash check, and `flutter test` (full suite, which includes the new suites). Every Epic PR shows the output.
- **Acceptance bar:** each finding in section 1 has a test that would have caught it. Most important: the handshake reaches `connected`; a dropped ack is retried; a remote `tempradio` is sent last; a release build contains no fake radio code.
- **Owner requirement (#748):** every error message these flows show is tested present on failure and absent under ideal conditions.

## 7. Done when

- The default `flutter test`, and so every PR's CI, connects the real connector to the fake radio and covers connect, sync, messaging, Companion presets and remote-node presets.
- The same fake radio runs from `tool/fake_radio.dart`, and the Windows app connects to it over TCP.
- Nothing under `lib/` imports the fake radio.
- The owner signs off D1, and `OUTCOMES.md` is approved.

## 8. Your choices

| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Where #601 lives | Move it into this Feature (A2); #598 depends on #755 | Leave it under #598 and build a second fake here | ⭐ A | |
| 2 | Manual runner (C3) | In this Feature | Later, separately | ⭐ A (it's the "USB cables are tied up" case, and small once the TCP adapter exists) | |
| 3 | Remote-node emulation (B3) | In this Feature | Later, separately | ⭐ A (it covers the #647 remote-preset gap in CI) | |

## 9. Carried-in work

| Item | Goes to |
|---|---|
| #601 (loopback fake radio, planned only) | A2 and A3 |
| #598 owner decision (not in CI) | Reversed for the fake radio only (2026-10-02, logged on #598) |
| #738 remote-preset test gap | C1 (in CI); D1 can include a real node if the owner wants |

## Alternatives considered but not chosen

- **`integration_test` on a Linux desktop runner in CI:** needs a display server and a full app build per run; the in-process adapter reaches the same screens from `flutter test`.
- **A Python or firmware-native simulator:** a second toolchain in CI, and it can't use the connector's in-process seam.
- **Running the real companion firmware on the host:** not investigated; it would mean building and maintaining a host port of the firmware, a much larger effort than this Feature.

When this plan merges, each Task gets a GitHub issue and a Citadel task, per canon.
