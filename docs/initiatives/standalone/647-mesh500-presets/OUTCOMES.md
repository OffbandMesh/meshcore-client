# Feature #647: outcomes

Written from what happened, including what failed. Plan: [PLAN.md](PLAN.md). All dates 2026-10-01.

## In plain language

Offband's radio presets now come from two files in the config repo: MeshCore's suggested settings (Liam Cottle's list, mirrored daily and credited) and our own overlay, which wins when both name the same preset. Regional entries like Philly Mesh, Arizona and the OKI 500 kHz test are there, grouped by region and labelled by source. Changing a preset is now an edit to `offband.json`, not an app release. The same presets can be applied to Companion and Observer radios, and to Repeaters, Room Servers and Sensors over stock admin commands, including a temporary option that reverts on its own.

The owner tested the combined build on his phone and Windows and approved it.

## What was delivered

| Epic | PR | What |
|---|---|---|
| A (#721) | config-profiles#3, merged | `radio-presets/offband.json` (33 presets), `meshcore-upstream.json` (mirror with credit), validator, workflow (validate on change, mirror daily) |
| B (#726) | #744 | Preset model and parsers, bundled copies, refresh with last-good cache, merge (ours over Liam's), grouped picker with source labels, Companion/Observer apply incl. path hash (cmd 61), About credit, #747 (USA radio shown as Canada) |
| C (#733) | #746 | Picker on remote settings, `set radio`, `tempradio` (sent last, 1 to 35791 minutes, default 1440), `set path.hash.mode`, Sensor admin entry (#745) |
| D (#737) | this PR | D1 owner test (#738), this document (#739), plan amendment, #748 tests |

## Evidence

- **Owner D1 (#738):** approved. In his words, in substance: it matches what he expected; he sees Philly, USA and the MeshCore entries; it is clean and reads well; the source labels are understandable; grouping by region is an improvement. His notes cover the preset picker; the per-node-type checklist items were not itemized in his reply.
- **Build tested:** local `throwaway/647-combined` @ `e1d30482`, containing #744 `04025cb0` and #746 `9c17f8a5`, release-signed, installed on the S25 FE and Windows.
- **Automated, same build:** analyze clean, 1087 tests pass, live preset test passes against config-profiles `main`.
- **CI:** every check green on #744 and #746 at those heads.
- **Config repo:** both files return HTTP 200 on `main`; validate passed on the merge push; the dispatched mirror ran end to end (no commit, Liam's list unchanged).
- **Acceptance bar (PLAN §6):** tests cover coding rates, path hash bytes to mode, `tempradio` ordering and its cap, and an overlay edit reaching the app with no release.

## What went wrong

- **The plan had a gap.** D1 checked preset refresh, but Epic A's merge was a stop at the end of the chain, so the files 404'd on `main` and that check could not pass. The owner was handed builds showing "Couldn't update presets. Showing the saved list." twice, and a third untestable handoff. Fixed by merging Epic A before D1 (PLAN §10).
- **No test touched the real dependency.** Every preset test faked the network, so the 404 passed all tests and CI. Fixed by #748: a live test in the default suite, so CI now fails if the files go missing.
- **A test build was installed mid-chain** on the owner's phone and Windows, replacing his working build. Both were restored to his earlier build until the chain was done. Canon now says an install is testing and happens once, at the end.
- **ADB diagnosis** blamed his phone before reading adb's own log; the real cause was a wedged USB link (`write terminated: Input/output error`), cleared by reconnecting.

## What's left

- Merge #744, then #746, then this PR, in that order (plan grant, budget 3).
- Owner sign-off on Epic verifications (#725 for A) and Epic closure.
- Remove the `throwaway/647-combined` worktree after merge.
