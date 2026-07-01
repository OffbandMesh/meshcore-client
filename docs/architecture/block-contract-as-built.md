# Block / Ignore — App ↔ Firmware Contract

**Status:** Proposed contract (design-of-record from the 2026-07 brainstorm). **Not yet built** — the
`-as-built` filename is the intended home for this doc; it will be reconciled to actual behavior as
Epic A / Epic B land. Sections marked **[TO LOCK]** require agreement with the firmware side
(`OffbandMesh/meshcore-firmware`, agent PearlMeadow — which **already has a block feature**) before
Layer 2 is coded.

**Owners:** app = meshcore-client (Offband); firmware = meshcore-firmware (Offband).
**Tracking:** Feature #164 → Epic A (app-local) #165 / Epic B (firmware offload) #166.
**Related:** device-config-parity Feature #7; firmware companion-API config command.

---

## 1. Problem

A single misbehaving node floods the mesh with **adverts, pings, DMs, and Public-channel posts**.
Users want to *ignore* that node so they stop seeing its traffic. Repeater/firmware-wide rate limiting
(`flood.max`, `flood.advert.interval`, region scoping) is a blunt, network-operator-level tool and is
explicitly **out of scope** here. This contract covers a **per-user, per-node block**.

## 2. Reality constraints (verified against the code + upstream)

1. **DMs and adverts carry the sender's public key** → blockable by identity, reliably.
2. **Channel/Public messages carry NO public key.** `ChannelMessage.senderKey` is always `null`
   (`lib/models/channel_message.dart`); the "sender" is a plaintext `"name: msg"` prefix. Public is a
   shared-PSK channel (`Channel.publicChannelPsk`). So channel senders can only be matched by
   **claimed name**, or by **resolving that name to a known contact's key**.
3. **There is no block primitive in stock MeshCore** — not in the companion protocol command set
   (tops out at `cmdSetPathHashMode = 61`, no block), not on the radio, not in the official app
   (its "Block Sender" is app-local UI filtering, same as MeshMonitor's "Ignored Nodes").
   → **Cross-app portability of a block is not achievable today by anyone.** A firmware-stored block
   is only meaningful as an **Offband-fork extension**; the stock app will not honor it.
4. **`cmdRemoveContact` (15) is not a block** — the firmware re-adds the contact on its next advert.
5. **Contact names track the pubkey.** On each advert, `_handleContactAdvert`
   (`lib/connector/meshcore_connector.dart`) replaces the stored contact with fresh advert data,
   including the current name (only the user path-override is preserved). This is what lets
   name→key resolution self-heal across renames (§5).

## 3. Core principle — two layers, app-authoritative, graceful degradation

```
Layer 1  App-local block          ── always on, any firmware. SOURCE OF TRUTH.
Layer 2  Firmware offload         ── Offband radios only, capability-gated. Best-effort mirror.
```

- **Layer 1** works identically on stock MeshCore and Offband firmware — full parity with the
  official app's behavior.
- **Layer 2** is an optional accelerator: on an Offband radio that advertises block capability, the
  app pushes the block down so the **radio drops that node's traffic before it reaches the app**
  (saves airtime surfacing / battery; persists across app reinstalls).
- The app never depends on Layer 2. If the firmware can't do it, Layer 1 still fully hides the node.

## 4. Layer 1 — app-local block (data model)

New `BlockStore extends ChangeNotifier`, persisted via `PrefsManager`, **scoped by the connected
device key** (first 10 hex chars — same pattern as `contact_settings_store`). Provider-wired alongside
the existing services.

Two sets:

| Set | Key type | Covers |
|---|---|---|
| `blockedKeys` | public-key hex | DMs, adverts, and channel posts that resolve to a known contact |
| `blockedNames` | lowercased display-name string | channel posts from senders with no matching contact (fallback) |

API: `isBlocked(keyHex)`, `isNameBlocked(name)`, `block(keyHex)`, `unblock(keyHex)`,
`blockName(name)`, `unblockName(name)`, plus read accessors for the management UI.

### Where blocks take effect (app side)

| Surface | Rule |
|---|---|
| Incoming DM | drop from thread + suppress notification when `senderKey ∈ blockedKeys` |
| Advert | in `_handleContactAdvert`: suppress new-advert notification; exclude key from Contacts + Discovery lists |
| Contacts / Discovery lists | filter out `blockedKeys` |
| Channel message | hide when it resolves to a blocked key (§5) OR `senderName.toLowerCase() ∈ blockedNames`, OR the channel is muted (§6) |

Blocking never deletes stored history; it hides. Unblock restores visibility.

## 5. Channel handling — name ↔ key resolution (the important part)

Channel packets are anonymous by protocol. To make channel blocking as strong as possible:

**At display:** a channel message is hidden if
`resolveContactByName(senderName)?.publicKeyHex ∈ blockedKeys` **OR**
`senderName.toLowerCase() ∈ blockedNames`.

**Long-press "Block sender" in a channel:**
- **Name resolves to a contact** → add that contact's **public key** to `blockedKeys` (this unifies the
  block: the node vanishes from the channel *and* DMs *and* adverts in one action). Also record the
  name in `blockedNames` as belt-and-suspenders.
- **No matching contact** → add the **name** only to `blockedNames`, surfaced with a clear
  "name-only — can be evaded by renaming" note.

**Why this resists rename evasion:** when the node renames, its next advert updates its contact's name
under the same pubkey (§2.5), so name→key resolution re-links automatically. Because this class of
abuser floods adverts, the link stays fresh in practice.

**Honest limitation:** if the node renames **and** the app never receives a linking advert (it goes
silent on adverts but keeps posting to Public), that specific post is genuinely unattributable — no
identity exists in the packet. Residual recourse is name-pattern matching or muting the channel (§6).
This is a protocol limit, not an app defect.

## 6. Per-channel mute (in scope, Layer 1)

Independent of per-sender blocking: a user can **mute an entire channel** (e.g. a noisy Public) so it
stops generating notifications/unread badges and is de-emphasized, regardless of who is posting. This
is the blunt-but-reliable answer to the unattributable-poster limitation in §5.

- Stored in the `BlockStore` (or the existing channel-settings store) as a set of muted channel
  indices / PSK identities, scoped by device key.
- Muting suppresses notifications + unread counts for that channel; messages remain readable when the
  channel is opened (mute ≠ leave).
- Toggle from the channel header/overflow and from the channel list (long-press).

## 7. Layer 2 — firmware offload contract  **[TO LOCK with PearlMeadow]**

Mirrors the existing `0xC1`/`offband_caps` capability pattern (`supportsOffbandGps` in the connector).
The firmware side **already has a block feature** — this section aligns the app to *its* real wire
format rather than inventing one.

- **Capability bit:** a `block` bit in the `offband_caps` bitfield in the device-info reply.
  App exposes `bool get supportsOffbandBlock => firmwareSupportsOffbandBlock(_offbandCaps);`.
  Stock firmware omits the byte → Layer 2 silently disabled. **[TO LOCK]** exact bit value.
- **Transport / representation [TO LOCK]:** how the radio stores + exchanges the block list
  (paginated `START → ITEM×N → END` list under a `block.*` namespace, vs a dedicated add/remove
  command with a sub-type byte). Adopt PearlMeadow's existing scheme.
- **Firmware behavior [TO LOCK]:** what the radio does with a blocked key (suppress delivery of that
  node's DMs/adverts to the companion; MAY drop relay on repeater builds). Record PearlMeadow's
  actual semantics here.
- **Capability-gated + additive** — stock MeshCore clients/firmware unaffected.

## 8. Sync model

- **App is authoritative.** `blockedKeys` in the app is the source of truth.
- On `block()/unblock()`: write local first; if `supportsOffbandBlock`, push the change to firmware.
- On connect to a capable radio: **reconcile** by pushing the current local block set down
  (mirrors `_reconcileGpsPolling`, tolerant of frame-arrival order).
- The app does **not** read firmware→app blocks; one-way push keeps a single source of truth.
  **[TO CONFIRM with PearlMeadow]** whether their existing feature expects a read-back / two-way merge.

## 9. Error visibility (per DifferentWire error-visibility rules)

- Firmware push failure surfaces a **persistent** snackbar (not a 4s flash); the local block still
  applies. Never swallow the error.
- All block/unblock/mute actions log with context (key/channel, surface, firmware-push result).

## 10. UX surfaces

- **Entry points:** contact context menu, chat overflow menu, Discovery item, channel message
  long-press (name-based, labeled), channel header/list (mute).
- **Management:** Settings → **Blocked** — list of entries (name if known + short pubkey), unblock
  action, muted-channels list, and an indicator of whether firmware-offload is active on the current
  radio.

## 11. Scope

**In scope (this contract):** app-local block of DMs + adverts by key; channel block via name↔key
resolution + name fallback; **per-channel mute**; capability-gated firmware offload.

**Deferred / out of scope (tracked separately, not silently dropped):**
- Content filtering (bullying/profanity/kids-mode) — explicitly future (original request item #3).
- Repeater / network-wide rate limiting — operator-level.

## 12. Decomposition

| Epic | Scope | Depends on |
|---|---|---|
| **A — app-local block** (#165) | `BlockStore`, filter points, name↔key channel resolution, per-channel mute, entry points, management UI | none — ships standalone |
| **B — firmware offload** (#166) | `offband_caps` block bit, config-command block list, sync/reconcile, capability UI | firmware wire contract §7 **[TO LOCK]** with PearlMeadow |

**Open items to lock before Epic B codes:** §7 representation (list vs command), firmware suppression
semantics, capability-bit value, and §8 read-back expectation. Coordinate with PearlMeadow
(`OffbandMesh/meshcore-firmware`); record decisions back into §7–§8 of this file.
