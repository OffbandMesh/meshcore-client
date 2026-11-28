# Feature PLAN: region scope keyed by channel identity + scope banner

| | |
|---|---|
| **Feature** | [#1255](https://github.com/OffbandMesh/meshcore-client/issues/1255) |
| **Serves** | Hardens Feature #812 (region scoping). Two Dot field reports: scope misbound on sync; a scoped-channel reminder would help. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-11-28 |

## At a glance
- **What:** key a channel's region scope by the channel PSK instead of the slot index so a sync cannot move it to the wrong channel; fix the Cyr2Lat setting the same way; and show a banner on a scoped channel.
- **Why:** region scope landed on the wrong channel after a sync for Dot even though everything else aligned, because scope is keyed by slot index and a reshuffle re-points it. A banner reminds the user a channel is scoped and lets them change it.
- **How:** adopt the PSK-keying pattern `channel_message_store` has used since #194/#1062, entirely client-side. Works on any firmware because the PSK comes from the radio.
- **Done when:** on hardware, a channel keeps its region scope across a resync (Dot's scenario); the Cyr2Lat setting survives a reshuffle; and a scoped channel shows a banner that opens Set Region Scope, is dismissible for the session, and returns on a fresh app open.

## 1. Diagnosis
Verified against client `dev`, 2026-11-28.

| # | Finding | Evidence |
|---|---|---|
| 1 | Region scope is keyed by **slot index**, so a sync reshuffle re-points it to whatever channel now holds that slot | `channel_region_scope_store.dart` `_key(channelIndex) => 'channel_region_scope_${publicKeyHex}_$channelIndex'` |
| 2 | Every other per-channel setting already keys by **PSK**; region scope and Cyr2Lat are the stragglers | `channel.dart:34` "the PSK is what every per-channel setting is keyed on"; `channel_message_store.dart` `_storageKey` keys `psk_<pskHex>` via `channelPskResolver` (#194/#1062); notify/settings use `channel.pskHex` throughout `meshcore_connector.dart` |
| 3 | Cyr2Lat has the identical bug | `channel_settings_store.dart` `'${keyForCyr2Lat}$channelIndex'` |
| 4 | The PSK is available on **any firmware** | `Channel.fromFrame` reads the 16-byte `psk` from the radio's channel frame; the client must have it to decrypt channel traffic, and has keyed messages/notify/settings by `pskHex` in production since 1.3.0. Resolver: `_findChannelByIndex(index)?.pskHex` |
| 5 | No scope indication in the channel UI | `channel_chat_screen.dart` has the Set Region Scope menu item but no persistent banner |

## 2. Scope
**In:** PSK keying + best-effort migration for the region-scope store (#1256) and the Cyr2Lat store (#1257); a scoped-channel banner (#1258); hardware verification (#1259).

**Out:** retained-region discovery (#1233, stays separate); the Offband firmware "channel key index" (firmware repo, a separate nicety, not required for correctness).

## 3. Decisions (owner, 2026-11-28)
- Key region scope by PSK, mirroring `channel_message_store`: active key `psk_<pskHex>`, index fallback only while the PSK is unknown (warn on read, error on write, never silent), and a one-time **best-effort** migration that maps the current index to the PSK on first read. An already-reshuffled scope may bind to the current slot occupant once, then stays put.
- **Banner:** shown while a channel is scoped, tappable to open Set Region Scope; dismissible per session (in-memory, keyed by PSK), reappears on each fresh app open (not persisted).
- **Fold in the Cyr2Lat store** fix (#1257).
- Retained-region discovery (#1233) stays separate.

## 4. Deliverables, in order
One branch, one PR, a commit per child issue (not stacked PRs). TDD throughout.

- **A. #1256 region scope -> PSK + migration** (P1, the bug). Inject `channelPskResolver`; key `psk_<pskHex>` when known; index fallback with logging otherwise; one-time best-effort adopt of an existing index-keyed value on first read. Regression test: indices swap, PSKs stable -> each scope stays on its own channel.
- **B. #1257 Cyr2Lat -> PSK + migration** (P2). Same change for `channel_settings_store`; reshuffle regression test.
- **C. #1258 banner** (P2). Bar at the top of `channel_chat_screen` when scoped: "Messages ride region <name>", tap opens Set Region Scope. Session-dismissible by PSK, returns on fresh open. Widget test: shown-when-scoped, hidden-when-dismissed, tap-opens-dialog. English string committed with `untranslated.json`.
- **D. #1259 hardware verification** (P2). Reproduce Dot's resync misbind and confirm the fix; confirm banner and Cyr2Lat. Android and Windows. Owner's test gate; the merge waits on it.

## 5. Grant terms

```grant-terms
{
  "epic_chain": [1255],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 1, "basis": "One PR for Epic #1255 with a commit per child (#1256 region scope PSK, #1257 Cyr2Lat, #1258 banner); merged after the owner's hardware verification (#1259)." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

`expires_after_hours` basis: three small, same-pattern storage/UI changes plus a hardware session at interactive pace around the owner's day job; 168h is the maximum and beats a re-mint mid-chain. No radio flash or reset, so both keys are null.

## 6. Risks
- Best-effort migration cannot un-mix a scope that already landed on the wrong channel before the fix; it binds to the current occupant once. Acceptable per the owner; the user can re-set. Data loss is avoided (the value is migrated, not dropped).
- A write that falls back to the index key would orphan a scope; mirror `channel_message_store` and log it as an error so it is never silent (SAFELANE 6).

## 7. Done when
Dot's resync keeps each channel's region; Cyr2Lat survives a reshuffle; the banner shows/dismisses/returns and opens the dialog; all on hardware, Android and Windows.
