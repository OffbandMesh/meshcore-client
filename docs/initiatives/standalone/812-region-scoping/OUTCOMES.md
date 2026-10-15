# Feature #812 region scoping: OUTCOMES

Status: shipped and verified on hardware (D1 PASSED, 2026-10-15). Client-only, no firmware change.

## What shipped
A client capability at parity with stock MeshCore, built on current stock-parity firmware:

- **Discover Regions** (Epic #814): from a reachable repeater, ask which flood regions it carries and present the list.
- **Channel Set Region Scope** (Epic #815): a per-channel region selection that makes a channel's outgoing messages ride that region's flood scope, orchestrated per send (set the flood-scope key before each channel send, clear after).
- **Protocol + transport** (Epic #813): the v8 companion frames and the region transport-key derivation that both of the above rely on.

### Epics / PRs
| Epic | Scope | PR |
|---|---|---|
| #813 | protocol + transport (anon-request discovery, flood-scope CMD 54/63/64, name-derived keys, version gate) | #824 |
| #814 | Discover Regions service + UI | #828 |
| #815 | channel Set Region Scope (store + picker + per-send scoping) | #833 |
| #816 | integration testing + this OUTCOMES.md | (this PR) |

## Wire contract (verified in firmware source)
- Region transport key = first 16 bytes of `SHA256("#"+name)` (`RegionMap.getTransportKeysFor` / `TransportKeyStore`). On-air code = `HMAC(key, type+payload)[:2]` little-endian, reserving `0x0000`/`0xFFFF`.
- Flood-scope: `CMD_SET_FLOOD_SCOPE_KEY` 54 (sub-0 set 16B key / sub-0 no-key clear / sub-1 unscoped), `CMD_SET_DEFAULT_FLOOD_SCOPE` 63, `CMD_GET_DEFAULT_FLOOD_SCOPE` 64, `RESP_CODE_DEFAULT_FLOOD_SCOPE` 28.
- Discovery is an ANON request: `CMD_SEND_ANON_REQ` 57 with payload `[ANON_REQ_TYPE_REGIONS 0x01][reply_path_len][reply_path]`. The firmware's `sendAnonReq` prepends its own 4-byte tag and returns it in `RESP_CODE_SENT`; the repeater echoes it in the `PUSH_CODE_BINARY_RESPONSE` 0x8C reply `[0x8C][0][tag:4][clock:4][CSV names]`. The reply routes back along the client-supplied `reply_path`, used as-is (`Mesh.cpp:176-177`).
- Version gate: `firmwareSupportsRegionScope` is `FIRMWARE_VER_CODE >= 13`.

## D1 hardware session (PASSED)
On a real radio (region-capable firmware, direct repeater), end to end:
1. Discover Regions returned the repeater's flood-allowed region list.
2. Set Region Scope persisted the chosen region on a channel.
3. A send on that channel rode the chosen region's flood scope.
4. The feature is hidden below the firmware gate.

## Issues found in D1 and fixed (all on epic/815-channel-scope)
D1 did its job; several defects only surfaced on real hardware.

- **Repeater picker unusable** (#830): the picker was an unsorted, unsearchable dropdown. Now alpha-sorted and searchable.
- **Path-aware picker** (#830, owner Option 1): the picker lists only repeaters with a usable route, with a note explaining that; a search surfaces path-less matches greyed out and non-selectable, labeled "No stored path".
- **Direct repeaters wrongly excluded** (#830): `hasPath` required a non-empty path, but a direct (0-hop) repeater has `pathLength 0` and an empty path. Direct is reachable (best case); fixed to `pathLength >= 0`.
- **Discovery returned no reply** (#836): two wire-format bugs. The client double-counted the anon-request tag (the firmware prepends its own), so the repeater read the request as a login and never answered; and the reply was correlated on a client-invented tag instead of the firmware tag the 0x8C echoes. Fixed to match the real contract.
- **Zero-hop reply cap** (#836): the reply was pinned to zero-hop, so only an adjacent repeater could answer. Now the request carries the repeater contact's stored path as the reply path (multi-hop), and the discovery timeout uses the firmware's own `est_timeout` estimate rather than a fixed value.
- **First-attempt LoRa drop** (#836, owner Option A): a single anon-request round-trip can drop over LoRa. Discovery now makes one automatic retry before reporting no response.

## Region model finding (firmware/repeater, not client)
A community discussion raised that `region def` on a repeater stores and displays regions as a hierarchy, and a region can only have one parent, which breaks tri-state-border configs (e.g. putting `oki` under both `us-midwest` and `us-southeast`). Verified in firmware: `RegionMap::findMatch` iterates regions as a **flat whitelist** at forward time (flood allow/deny flag plus a transport-code match) and never consults `parent_id`. So the hierarchy is cosmetic; the re-parenting on `region def` is a repeater-side config/doc UX flaw, not a routing behavior. Our client scopes a channel by the flat tag name and discovers the flat list of flood-allowed names, so it is already aligned with how the firmware routes and is unaffected by the hierarchy issue.

## Known limits / follow-ups
- The multi-hop reply uses the repeater contact's **stored** path. Stored paths go stale when the companion moves, so a repeater can occasionally not answer until the path refreshes; this surfaces as a plain timeout (plus the one auto-retry), never a silent drop. The repeater list is deliberately not filtered by hop count for the same reason.
- `$`-prefixed private regions are not name-derivable (keystore-only) and are out of scope.
- A true per-channel firmware scope (firmware TODO) would remove the client-orchestrated per-send dance; sequenced separately by the owner.
- Android was not built for D1 (release signing needs the keystore in the worktree); the owner tested on Windows, and the same client code runs on both.

Agent: EmeraldFalcon (session 6966cd3a)
