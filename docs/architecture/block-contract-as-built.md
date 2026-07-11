# Block / Ignore — App ↔ Firmware Contract

**Status:** App-side design-of-record (2026-07), **app half not yet built**. Reconciled to the firmware
side, which is **merged / as-built** (`OffbandMesh/meshcore-firmware`, PR #247, `FIRMWARE_VER_CODE 15`;
Feature #241 / Epic #242 / doc #244). Wire codes below are the firmware **as-built** values, **design +
all wire gaps confirmed by PearlMeadow** (reply 2026-07-01: reply-shape, overflow-at-32, early-END
re-request, no-unsolicited-push). The app half is reconciled to the shipped firmware; no open
discrepancies.

**Owners:** app = meshcore-client (Offband); firmware = meshcore-firmware (Offband, agent PearlMeadow).
**Tracking (app):** Feature #164 → Epic A (app-local) #165 / Epic B (firmware offload) #166.

---

## 1. Problem

A single misbehaving node floods the mesh with **adverts, pings, DMs, and Public-channel posts**.
Users want to *ignore* that node so they stop seeing its traffic. Repeater/network-wide rate limiting
is operator-level and **out of scope**. This contract covers a **per-user, per-node block**.

## 2. Reality constraints (verified — app + firmware)

1. **DMs and adverts carry the sender's public key** → blockable by identity, reliably.
2. **Channel/Public messages carry NO public key.** `ChannelMessage.senderKey` is always `null`
   (`lib/models/channel_message.dart`; firmware `BaseChatMesh.cpp:367-387`); sender is a plaintext
   `"name: msg"` string over a shared PSK. Channel blocking is a **name↔key resolution** problem.
3. **No block primitive in stock MeshCore.** So a firmware-stored block is meaningful only as an
   **Offband extension**; a stock/other client will not honor it.
4. **`cmdRemoveContact` (15) is not a block** — firmware re-adds the contact on its next advert.
5. **Contact names track the pubkey.** On each advert, `_handleContactAdvert`
   (`meshcore_connector.dart:4639`; firmware `BaseChatMesh.cpp:120,177,186`) refreshes the stored
   name under the same pubkey — this powers the self-heal (§5).

## 3. Core principle — app-local is never abandoned; firmware is a portability bonus

```
Layer 1  App-local block   ── ALWAYS on, any firmware. The client's source of truth. Never wiped by sync.
Layer 2  Firmware offload  ── Offband nodes only, capability-gated. Portable store + DM-drop. Additive.
```

- The app owns a **complete, self-sufficient block** on any firmware (stock/other/Offband).
- On an **Offband** node the app *also* syncs with the node's store, so the block **follows the user to
  other Offband clients**. On a **non-Offband** node the block still works and persists **locally** — it
  just can't ride that node to your other devices.
- **Blocking never depends on Layer 2**, and **sync never silently unblocks anyone** (§8).

## 4. Layer 1 — app-local block (data model)

New `BlockStore extends ChangeNotifier`, persisted via `PrefsManager`, **global to the app (keyed by
public key), NOT per-radio-scoped** — deliberate deviation from the `contact_settings_store`
per-device convention, because a block is "I don't want to see *this person*" and identity is a pubkey
regardless of which radio is connected. (Revisitable later.)

Two sets:

| Set | Key type | Covers |
|---|---|---|
| `blockedKeys` | public-key hex (full 32-byte identity) | DMs, adverts, and channel posts that resolve to a known key |
| `blockedNames` | lowercased display-name string | channel posts from senders not resolvable to a key (fallback; self-pruning, §7) |

API: `isBlocked(keyHex)`, `isNameBlocked(name)`, `block(keyHex)`, `unblock(keyHex)`,
`blockName(name)`, `unblockName(name)`, plus read accessors for the management UI.

### Where blocks take effect (app side)

| Surface | Rule |
|---|---|
| Incoming DM | drop + suppress notification when `senderKey ∈ blockedKeys` (on Offband, firmware already dropped it at receive — §7) |
| Advert | suppress the new-advert notification for `blockedKeys`. **Do NOT discard the advert** — the contact-name update must keep flowing (self-heal, §5) |
| Contacts / Discovery lists | **keep blocked entries VISIBLE** with a clear blocked indicator — a red block icon (`Icons.block`, circle-with-slash) + muted/greyed styling. **Do NOT hide them.** Inline unblock available. *(A "hide blocked entirely" toggle is a deliberate post-implementation follow-on, not v1.)* |
| Channel message | hide per the resolution rule in §5 |

Blocking hides, never deletes history. Unblock restores.

## 5. Channel handling — name ↔ key resolution

Channel packets are anonymous, so resolution runs against a **name↔key index** (§ below).

**At display — hide a channel post only if:**
`resolveKeys(senderName)` is non-empty **and *every* matching pubkey ∈ `blockedKeys`**,
**OR** `senderName.toLowerCase() ∈ blockedNames`.

If **any** matching pubkey is **unblocked → SHOW**. An ambiguous name (two people/devices sharing a
name) must not censor a possibly-legit namesake (false-positive L1).

**Long-press "Block sender":**
- resolves to one key → add to `blockedKeys` (**one action unifies DM + advert + channel**; sync to fw).
- **multi-match** (one person on multiple devices = multiple keys, same name) → surface *all* matching
  keys so the user blocks each device's key.
- no resolution → add to `blockedNames`, flagged "name-only — evadable by rename."

**Name↔key index — sourced from BOTH (don't rely on one push type):**
- **`PUSH_CODE_NEW_ADVERT` (0x8A)** — full record (pubkey + name), fires for every advert from a
  sender **not** in the node's contact store, **no replay guard** → an unstored spammer always
  resolves (closes the "permanent name-only" worry).
- **the synced contact list** — a renamed **stored** contact re-adverts as `PUSH_CODE_ADVERT` (0x80,
  **pubkey only, no name**); read the new name from the contact record, not the advert tickle.

**Why rename evasion mostly fails:** a renamed sender's next advert refreshes the name under the same
pubkey, so resolution self-heals — and an advert-flooder keeps that link fresh.

**Honest limit (L3):** renamed **and** advert-silent but still posting to a channel = genuinely
unattributable (no identity in the packet). Not closable app- or firmware-side; the recourse is the
global name-fallback block (§6), which upgrades to a pubkey block once the identity is seen (§7).

## 6. Global name-fallback block + evasion scope

When a channel sender **can't** be resolved to a pubkey, "Block sender" adds the lowercased name to the
app-global `blockedNames` — so that name is hidden in **every** channel, immediately. The user never
blocks channel-by-channel; one action covers all channels. The name block is provisional and upgrades
to a durable pubkey block the moment the identity is learned (§7).

**Out of scope (current MeshCore):** a determined troll can dodge a name block with a one-character or
invisible-Unicode rename. Defeating that is a larger anti-abuse problem than MeshCore's channel model
allows today (channel posts carry no per-post identity) and is explicitly **not** in this design. The
durable answer is pubkey promotion (§7) once we ever see them by key — their advert or a DM.

## 7. `blockedNames` promote-and-prune

A name-only block is provisional. When a `blockedNames` entry links to a pubkey — via their **advert**
OR a **DM** (any time we learn the key) — **promote** it: add the pubkey to `blockedKeys` (sync), drop the name entry. Any name that never links
**expires after ~30 days**. The durable block is always the pubkey; `blockedNames` stays small and
self-cleaning, bounding the L1/L2 false-positive window.

## 8. Layer 2 — firmware offload + sync (Offband only)

Mirrors the `0xC1`/`offband_caps` capability pattern (`supportsOffbandGps`). Values are firmware
**as-built** (merged PR #247, `FIRMWARE_VER_CODE 15`):

- **Capability:** `OFFBAND_CAP_BLOCK = 0x02` (bit 1) in the capability byte of `RESP_CODE_DEVICE_INFO`
  (reply to `CMD_DEVICE_QUERY`); gated on `FIRMWARE_VER_CODE ≥ 15` **and** the bit set. App exposes
  `bool get supportsOffbandBlock => firmwareSupportsOffbandBlock(_offbandCaps);`. Bit absent →
  **app-only mode** (no sync, no firmware drop); block still works locally.
- **Command:** `0xC2 = CMD_OFFBAND_BLOCK`, sub-typed (0xC0=config, 0xC1=GPS already used):

  | Sub | Name | Frame | Reply |
  |---|---|---|---|
  | `0x01` | BLOCK_ADD | `[0xC2][0x01][pubkey:32]` | `[0xC2][0x01][ok]` — ok=1 present-after-call, ok=0 store-full |
  | `0x02` | BLOCK_REMOVE | `[0xC2][0x02][pubkey:32]` | `[0xC2][0x02][ok]` — ok=1 removed, ok=0 not-present |
  | `0x03` | BLOCK_LIST | `[0xC2][0x03]` | streamed dump (framing below) |
  | `0x04` | BLOCK_CLEAR | `[0xC2][0x04]` | `[0xC2][0x04][ok]` |

  **Reply shape (as-built):** success is always the 3-byte `[0xC2][sub][ok]` — `ok` is a *result byte*,
  not a separate ack/err frame. The **only** error frame is the generic **`[0x01][0x06]`**
  (`RESP_CODE_ERR=1`, `ERR_CODE_ILLEGAL_ARG=6`), emitted for a malformed request (ADD/REMOVE < 34 B or
  unknown sub). ⚠ **It is NOT `0xC2`-prefixed** — the app must recognize the generic 2-byte error frame
  and must **not** wait for a `0xC2` echo.

  **`BLOCK_LIST` dump framing (as-built):** START `[0xC2 0x03 0xFF count]` → one key per idle pass
  `[0xC2 0x03 index pubkey:32]` → END `[0xC2 0x03 0xFE]`. On an `APP_START` reconnect mid-dump the
  firmware emits an **early-END terminator** so the app never blocks on a stale stream. Normal END and
  early-END are the **identical byte** (`0xFE`); detect truncation by comparing the START `count`
  against key-frames received — **fewer ⇒ truncated ⇒ re-request `BLOCK_LIST` when the link settles.**
  Never treat a partial dump as authoritative, and **never derive removals from a LIST** (removal is
  explicit-unblock only) — a partial pull can only miss node keys (fixed by re-request), never
  false-unblock.

- **Firmware store:** list of blocked pubkeys in NVS (flat `/blocks` file), **independent of the
  contacts list** (block a spammer without storing them). **`MAX_BLOCKED_KEYS = 32`** (as-built).
  **Overflow:** if the app's local list exceeds 32, the overflow `ADD` returns `ok=0` (**not** an
  error) — those keys simply aren't node-portable; **tolerate it, local stays authoritative.**
  Idempotent nuance: an already-stored key returns `ok=1` even at capacity (dedup short-circuits before
  the full check), so `ok=0` strictly means "new key + store full."
- **Firmware enforcement:** DM from a blocked key → **dropped at receive** (the core offload) —
  **silently**: no notification, no frame. The app never sees blocked DMs and cannot count/badge them,
  so any "N blocked" UX must not rely on firmware counts. Adverts → **still processed** (keeps
  self-heal alive); app suppresses the *notification*. Channel → **not** enforced in firmware (app-only).
- **No unsolicited pushes.** Block state is strictly app-pull + app-initiated ADD/REMOVE/CLEAR/LIST;
  the only firmware-initiated `0xC2` frame is the `APP_START` early-END terminator (a reconnect signal,
  not a state change).

### Sync model — union, app always retained

- **App-local is never wiped by sync.** The only removal is an explicit user **unblock**.
- **On connect to an Offband node:**
  1. Pull `BLOCK_LIST` (`0xC2/0x03`).
  2. **Add** node entries missing locally → local. *(Never remove a local entry.)*
  3. **Push** local entries missing on the node → `BLOCK_ADD` (`0xC2/0x01`).
  4. Both converge to the **union** → portable to the user's other Offband clients.
  - Reconcile is tolerant of frame-arrival order (mirror `_reconcileGpsPolling`).
  - If the dump was truncated (START `count` > key-frames received, e.g. `APP_START` early-END),
    **re-request** once the link settles; treat only a complete dump as the node set.
- **Unblock:** remove locally **and** `BLOCK_REMOVE` (`0xC2/0x02`) on the node.
- **On a non-Offband node:** steps skipped; local store does everything (not portable via that node).

## 9. Error visibility (per DifferentWire rules)

- Firmware push/pull failure surfaces a **persistent** snackbar (not a 4s flash); the local block
  still applies. Never swallow.
- All block/unblock/sync actions log with context (key/channel, surface, fw result).

## 10. UX surfaces

- **Entry points:** contact context menu, chat overflow, Discovery item, channel message long-press
  (name-based, labeled).
- **Blocked contacts stay in-list** with a red block badge + muted styling (not hidden); unblock inline from the tile. A future "hide blocked entirely" setting is a post-impl follow-on.
- **Management:** Settings → **Blocked** — list (name if known + short pubkey), unblock, and an
  indicator of whether firmware offload/sync is active on the current radio.

## 11. Interop invariant (binding — from firmware §11)

Block is a **per-user view filter + a portable list synced over the local companion link**. It **MUST
NOT** alter forwarding, relaying, ACKs, advert re-flood, or any RF behaviour. A blocked sender's
packets still route and flood **through** the node normally; the drop happens at the **app-push layer,
after routing** — never in the forward path. Blocking someone must never make the node a worse relay.
All wire additions (`0xC2`, cap `0x02`) are companion-API frames (BLE/USB, `0xC0+` namespace) that
never traverse LoRa. Fully compatible with stock MeshCore / non-Offband nodes.

## 12. Known gaps (carry into implementation)

- **G1** — contact-name re-link only takes when the advert `timestamp` strictly increases
  (`BaseChatMesh.cpp:123`); a clock-skewed/replayed advert can briefly stall a rename re-resolve.
- **L1** — spoof-into-block: channel names are attacker-controlled; someone can post as a blocked name
  (hidden) or impersonate a blocked name to hide a legit person. Low severity; §5 "any-unblocked→show"
  and §7 age-out bound it.
- **L2** — stale name post-rename may catch an innocent who later reuses it; mitigated by §7.
- **L3** — zero-identity hard limit (§5) — protocol, not closable.

## 13. Scope

**In scope:** app-local block of DMs + adverts by key; channel block via name↔key resolution + global
name fallback (with promote-to-pubkey); capability-gated firmware offload + union sync.

**Deferred / out of scope:** content filtering (kids-mode/profanity) — future (original item #3);
repeater/network-wide rate limiting — operator-level.

## 14. Decomposition

| Epic | Scope | Depends on |
|---|---|---|
| **A — app-local block** (#165) | `BlockStore` (global), filter points, name↔key channel resolution + index, global name-fallback + promote-and-prune, entry points, management UI | none — ships standalone |
| **B — firmware offload** (#166) | `OFFBAND_CAP_BLOCK` detection, `0xC2` ADD/REMOVE/LIST/CLEAR, union sync/reconcile, capability UI | firmware Feature #241 (codes finalize at fw implementation) |

**Cross-project alignment:** firmware doc #244 ↔ this doc. Remaining firmware-side opens (their §10):
block-store capacity, non-contact auto-add policy, final `0xC2` codes + dump framing.
