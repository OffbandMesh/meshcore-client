# Population classifier contract (F1, #862)

What the client's `DevicePopulation` classifier promises, what it consumes, and the one seam where the firmware's durable marker (decision D1) replaces the interim heuristic. This is the client's half of the D1 coordination; the firmware input is filed on [#857](https://github.com/OffbandMesh/meshcore-client/issues/857).

## Promise

Every capability decision in the client routes through `classifyDevicePopulation` (`lib/connector/device_population.dart`). No code reads `firmwareVerCode` comparisons at or above 14, or device-info frame offsets 82+, outside it — the population invariant is documented at the gate block in `meshcore_protocol.dart` and locked by the stock-ver-22 regression test.

| Population | Fork frames (0xC0–0xC6) | CLI frame 66 | How recognized today |
|---|---|---|---|
| `stockLegacy` (and every conflict/unknown) | no | no | fail-closed default |
| `stockModern` | no | yes | 82-byte device-info, ver ≥ 14, no contradicting version string |
| `offband` | per cap bits | no (flips at this seam post-absorb) | >82-byte device-info **corroborated** by the dual version string |

## Interim signals (in precedence order)

1. Device-info frame length: 82 = stock layout; 83/85 = fork layout (caps byte offsets 82/84).
2. Version string shape (`classifyVersionString`): bare semver = stock; semver-dash-remainder = Offband dual (incl. `X-X` release images, firmware#691, and git-describe bench tails); anything else corroborates nothing.
3. Ver code: only meaningful below 14 (pre-split floors ≥8, ≥13) or inside caps-anchored fork gates (15/17/22, config 14).

Conflicts (fork shape + stock/absent string, stock shape + dual string, ver > 32) classify `stockLegacy` with `conflict: true` and the evidence logged.

## The D1 seam

When firmware ships its durable population marker, **`classifyDevicePopulation` is the only place that learns to read it**; `Classification` and every caller are unchanged. The same change flips `allowsCliFrame` for post-absorb Offband devices. What the client needs from the marker, stated as requirements rather than a mechanism:

- carried in the device-info reply (no extra round trip),
- distinguishes fork from stock regardless of future stock frame growth (the 82-byte assumption is one upstream append away from dying),
- readable before any capability decision is taken,
- stable across the VER_CODE renumbering, whatever D1 picks.

## Known limitations (all fail closed)

- A fork device whose version string cannot be read loses fork features for that connection (uncorroborated shape).
- A hypothetical stock pre-release string (`vX.Y.Z-rc1`) reads as dual → inverse conflict → `stockLegacy`.
- A future stock device-info longer than 82 bytes will conflict with its stock version string → `stockLegacy` until the D1 marker exists. This is the designed behavior, not a bug: it is exactly the case the marker solves.

Agent: GentleGlacier (session f0c92a36)
