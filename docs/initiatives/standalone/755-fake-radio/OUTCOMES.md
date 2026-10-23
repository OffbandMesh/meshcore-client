# Feature #755: outcomes

Written from what happened, including what failed. Plan: [PLAN.md](PLAN.md). Dates are 2026-10-04 to 2026-10-23.

## In plain language

The app's tests can now connect to a radio that isn't there. A fake MeshCore companion radio, written in Dart, answers the same frames a real one does, copied from the firmware source. It plays stock MeshCore or Offband firmware. Every PR's CI connects the real connector to it under both, and covers connect, sync, messages, acks and retries, Companion presets, and remote presets on a repeater, room server and sensor. CI also fails when the client's protocol codes disagree with the firmware's.

To check the fake against real firmware, two real radios were recorded: a Heltec V4 on stock MeshCore 1.18.0, and a RAK4631 on Offband 1.5.0-beta7. A fake loaded from each recording gives every reply that radio gave, byte for byte, with one exception: leftover bytes after the NUL that ends a channel name are not compared. The recordings were anonymized before they were committed, though the first version missed two things (see What went wrong).

The same fake runs as a program on a PC (`dart run tool/fake_radio.dart`), so the desktop app can connect to it over TCP with no radio attached. The owner has not yet run the app against it, which is the remaining half of D1.

## What was delivered

| Epic | PR | What |
|---|---|---|
| A (#756) | #786 | Core (frame codec, dispatch, seeded state, a clock tests control), in-process and TCP adapters, stock and Offband profiles from pinned protocol manifests, the manifest contract check, a connector seam (`connectInProcessForTest`) |
| B (#757) | #788 | Messaging and acks, radio settings, remote nodes (login, CLI, `tempradio` timing), scripted faults, trace capture (`capture_trace.py`) and replay |
| C (#758) | #797 | Connector scenarios under both profiles, channel and chat screen tests, the manual runner and its seed file format, the release guard |
| D (#759) | this PR | Two real-radio traces as fixtures, `anonymize_trace.py`, the conformance test, stock re-pinned to `companion-v1.18.0`, this document |

## Evidence

- **Full suite at this PR's head:** `flutter analyze` clean; `flutter test` 1234 passed, 1 skipped (`real_store_rehearsal_test.dart`, which predates this Feature). The 146 fake-radio tests all ran, none skipped, including the Python capture against the runner and `dart run tool/fake_radio.dart`.
- **Real radios (D1 captures, D2):** 51 requests each, one answer per request.
  - Stock: Heltec V4, `v1.18.0-81dbae5`, code 14, 82-byte DEVICE_INFO, 40 channels, 350 contacts. Replay: no differences.
  - Offband: RAK4631, `1.5.0-1.17.0`, code 22, 87-byte DEVICE_INFO, caps `0x22`, caps2 `0x0e`. Replay: no differences after the seeding fix below.
  - Each pinned profile matches what its radio reports: version code, version string (stock appends the commit, `81dbae5`, which matches the pinned manifest's commit), DEVICE_INFO length, and every capability bit the profile sets.
- **Anonymization:** every real key, name, position, channel secret, path fragment (3 bytes or more) and contact advert time was searched for in the fixtures. The counts are stock / Offband:
  - keys 351 / 349;
  - names 365 / 365;
  - positions 309 / 285;
  - advert times 687 / 545.

  None was found. The only match was the all-zero secret of an empty channel slot. The same search finds every one of them in the raw captures, so the check can fail.
- **Gemini adversarial gate** (`llm-consult.py`, `gemini-2.5-pro`), one review per Epic, with the firmware source at the pinned tags. A: 8 findings, B: 6, C: 7, D: 9. Each was checked against the code and firmware before acting. Fixed or rejected with a reason in each Epic's PR body.
- **Determinism:** same seed, same result over 20 connects (A6). After its flake fix, the TCP connect test passed five full clean runs.
- **Acceptance bar (PLAN §6):** the handshake reaches `connected` under both profiles and both adapters; the stock profile sees no Offband feature or command; the manifest check fails on a doctored constant; a dropped ack is retried; a remote `tempradio` goes last; nothing under `lib/` imports the fake (and the guard catches each way it could).
- **#748 requirement:** remote preset apply checks that no error text appears on a good save, and that the firmware's error text comes back on a refused one (`connector_scenarios_test.dart:264-297`).

## Findings

Things the fake radio work turned up in the client or firmware. None is fixed in this Feature.

| # | Finding | Evidence | Status |
|---|---|---|---|
| 1 | The client re-polls channels on push `0x91` (`pushCodeChannelsChanged`), which no firmware defines | Not in the pushes of `offband-v1.5.0-beta7` or `companion-v1.18.0` (highest is `0x90`); listed as client-only in `manifest_contract_test.dart` | Recorded; the push is never sent, so the re-poll never runs |
| 2 | A DM's delivered tick needs non-empty path bytes | `chat_screen.dart:1836-1839`: `isAcked` is `delivered && pathBytes.isNotEmpty` | [hypothesis] a DM delivered by flood shows no tick. Untested: the fake reports paths from its seed, and no test covers a flood-delivered DM |
| 3 | A stock repeater's frequency shows as `910.5250244` in Repeater Settings | Stock prints the frequency with `ftoa`, the float32 at seven decimals (`CommonRadioPrefs.cpp:35,61` in 1.18.0; `CommonCLI.cpp:861,901` in 1.17.1). Offband uses `ftoa3`. The client puts the text in the field as is (`repeater_settings_screen.dart:413`) | Cosmetic. Preset matching rounds to whole kHz (`remote_radio_commands.dart:91`), so it still matches |
| 4 | Both firmwares never send a contact whose `lastmod` is 0, but count it | `CMD_GET_CONTACTS` counts every contact (`MyMesh.cpp:2728`, "total, NOT filtered count") and sends only `lastmod > since` (`:3868` Offband, `:2397` stock). The RAK4631 announced 350 and sent 348 | Recorded. Those two contacts are on the radio but in no app. How they got `lastmod` 0 is not investigated |
| 5 | Offband caps2 depends on the board | The RAK4631 adds BUTTON_MATRIX and INDICATORS (`MyMesh.cpp:2486-2494`); the pinned profile sets only the bit every board sets, PKT_HASH | The conformance test allows a board's extra bits |

## What went wrong

- **The first fixtures were not fully anonymized, and they are public.** Pushed with #942 on 2026-10-20 and still reachable in that PR's history, they held:
  - 13 bytes of real path data that firmware leaves past the end of a contact's path. Those are fragments of real repeaters' key prefixes; the anonymizer rewrote only the bytes inside the path.
  - Every contact's real advert times. A public observer's log could match those back to the real nodes, and so to the owner's region.

  Found by the Gemini review. The anonymizer now rewrites every nonzero path byte and replaces advert times. It also refuses any reply type or custom variable it does not know, and replaces GPS coordinates in the Offband GPS status text. Both fixtures were regenerated and re-checked.
- **The Gemini adversarial gate was skipped on all four Epics.** `/pushpr` makes it required; every PR went up without it. Run on 2026-10-22, before the rebased stack was pushed.
- **Citadel tasks D2 and D3 were closed before CI was green,** which `/pushpr` forbids. Reopened.
- **The fake's stock remote node used Offband's number format.** B3 copied `get radio` from Offband's `CommonCLI` for both profiles; stock formats the frequency differently (finding 3). It came out while checking the 1.18.0 re-pin. Fixed, with the Dart port checked against the firmware function compiled with g++.
- **The capture script filed Offband replies as pushes.** It treated every code from `0x80` up as a push, and Offband replies are `0xC0` to `0xCF`. The end-to-end test that runs the script against the runner caught it before any real capture.
- **The first real captures misfiled answers.** A radio answers slowly right after the port opens, and one answered a step late, so replies landed under the next request. The script now waits for the first answer before timing anything, and waits up to 5 seconds per step. Both radios were recaptured clean. The conformance test checks one answer per request, because a misfiled capture can still replay clean.
- **The trace seed lost two contacts** the radio counted but never sent (finding 4). The seed now adds a hidden stand-in for each, so the fake's count matches.
- **A TCP connect test was flaky,** sampling the radio's received commands before the last one arrived. I committed and pushed before reading a failure line in my own test output. Fixed on Epic A and merged forward.
- **The runner instructions failed for the owner.** He ran `dart run` with the machine's default Dart (3.7.2), which fails on native assets. The README now says to use the Dart from the Flutter SDK the repo builds with.
- **The plan's flash term named no device,** so `dw-approve` refused it. Fixed in the plan by #766 (flash gets its own grant once the radio is chosen).
- **A stray Agent Mail project (id 42)** blocked the session hooks for a while; the lookup now resolves to the right project (15).
- **A bare `git push` tripped the merge gate,** which read it as a push to `dev` and sent a merge-approval alert to the owner's radio. Nothing merged. Pushes now name the branch.

## What's left

- **D1, owner step:** connect the Windows app to `tool/fake_radio.dart`, once with `--profile offband` and once with `--profile stock`. The two captures are done.
- Merge #786, #788, #797, then this PR, in that order (plan grant, budget 4).
- Owner sign-off on D1 and approval of this document.
- Older firmware profiles: #932 (backlog).
- Switch the pinned manifests to the ones firmware#1318 will publish, when it lands.
- Remove the four worktrees after merge.
