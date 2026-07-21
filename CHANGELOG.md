# Changelog

All notable changes to Offband Meshcore. Pre-releases are tagged `-beta.N` / `-rc.N`.

## [1.2.0] - 2026-07-21

A major uplift: the storage engine moved to a real database, the app got a new
navigation shell, and GIFs are now shareable across MeshCore clients. First
release cut end-to-end through CI (signed, all platforms).

### Storage

- **Bulk data (messages, contacts, channels, and more) now lives in a drift /
  SQLite database** instead of individual SharedPreferences entries. Existing
  data is **migrated automatically on first launch** and preserved, not
  discarded (#335, #355, #348).
- The database is stored in the app-support directory, so it is not caught up in
  OneDrive/Documents sync on desktop (#335).
- Message history is kept in full; only the in-memory window is bounded, so
  reopening a conversation no longer risks losing older messages (#343).
- Storage failures that used to fail silently now surface (#306, #333).

### Navigation

- **New app shell with a hamburger nav drawer that can be pinned open** (#292).
- The channel list lives in the drawer and is switchable from inside a channel;
  channels swap in place so a pinned panel stays put (#289).
- Map layer toggles moved into the nav panel; Disconnect and Settings moved into
  the panel footer (#291, #290).
- Contacts gained a prebuilt filter rail, including a Sensors type (#307, #308).
- Back-button behavior fixed: back now backgrounds the app instead of killing
  it, and no longer drops a user off a connected radio (#291).

### GIFs

- GIFs are now shared as a **Giphy URL** instead of the Offband-only `g:<code>`,
  so other MeshCore clients can open them (#282).
- Pasted Giphy / Tenor URLs render inline, behind a trusted-host allowlist
  (#283, #284).

### Other features

- Desktop window position and size are remembered across launches (#349).
- Reach a contact's settings from its long-press menu (#351).
- FEM LNA toggle in Radio Settings and Offband capabilities shown in Device Info,
  gated on firmware support (#304).
- Message arrival time (rxTime) is logged and persisted, distinct from the
  claimed send time (#285).

### Fixes

- You can no longer accidentally block your own node (#250).
- Path length decodes per the firmware contract (width-aware), and path
  diagnostics report units truthfully (#309, #298).
- Connecting no longer rewrites the entire preferences file per channel (#306).

### Under the hood

- Every release is now built, signed, and published across Android, Windows, and
  Linux automatically through CI. A web build is wired up and coming soon.

## [1.1.2-rc.3] - 2026-07-17

Combined entry for rc.2 (versionCode 59) and rc.3 (versionCode 60). Both shipped
to the Play closed test with only a version bump; this backfills the changelog
they should have carried.

### Added
- Block / mute system: block a contact or a channel sender from contacts, DMs,
  discovery, or a channel message; blocked DMs and adverts are suppressed with a
  visible marker, and a name-only block promotes to the sender's public key on
  the next advert or DM and ages out after 30 days. Managed from Settings →
  Blocked. Synced to firmware on connect where the radio supports it (#168–#180,
  #172–#174, #169, #170).
- Per-channel notification modes: a 3-way selector (all / mentions / mute) on the
  Channels screen, applied at the notification gate and stored keyed to the
  channel PSK (#260, #261, #262).
- Path trace and topology: width-matched path tracing, a topology service and
  readout, RX ingestion, and a route-builder UX that groups hops by hash width
  rather than raw bytes (#150, #186, #156, #155, #224).
- Channel QR: share a channel as a scannable QR and scan one to add it, unified
  with the community scanner and using the reference-app format (#163).
- Own device public key is now full, selectable, and one-tap copyable (#234).
- Reply-to chip shown above a reply-gif, with inline `@[Name]` mention chips
  (#235).
- GPS refresh falls back to stock-firmware self-telemetry when the fork-specific
  query is unavailable, chosen by firmware capability (#123).
- Queue-sync diagnostics: a file log of queue-drain activity plus a manual
  force-drain action (#51).

### Fixed
- USB open no longer wedges ESP32-C6 boards: the DTR open pulse is gated by USB
  vendor ID, so it fires only for nRF52 reconnect and is skipped for chips it
  would reset into ROM download mode (#248).
- Outgoing DMs to a blocked contact are dropped at the send path (#252).
- Contact path-length byte decodes at the device's hash width instead of being
  read as a raw byte count (#224).
- Stale channel slot history is cleared on channel reassignment, and the message
  store's device-key scope is aligned (#193, #194).
- Enter selects the highlighted emoji or mention in autocomplete (#238).
- Manual path entry honors the configured path-hash width (#155).

### Changed
- The fork-only GPS query is gated on firmware capability, so stock and
  non-Offband radios degrade gracefully instead of erroring (#123, #144).

## [1.1.2-rc.1] - 2026-06-28

### Added
- Channel reply UX: replying focuses the composer, and one-click route-reply sends
  back along the path the message arrived on (#131, #106).
- Device Info shows the connected radio's firmware version and model, and logs them
  to the app log on connect (#134).
- GPS state query — when a GPS-capable radio (Offband firmware) has GPS enabled,
  read its live GPS state (detected / fix, coordinates, satellites) from
  Settings → Location (#135).

### Fixed
- BLE write flood (`recv_queue` / `send_queue` full) during sync on slower links:
  the per-minute GPS refresh no longer re-initializes the whole device each minute
  (which had been re-walking channels and re-draining messages) (#140).
- Repeater path-hash labels decode at the device's hash width, so multi-byte hashes
  render correctly (#115).

### Changed
- The fork-only GPS query (`0xC1`) is gated on firmware capability, so stock /
  non-Offband MeshCore radios are never sent a command they can't answer; the GPS
  status section is hidden on unsupported firmware (#144).

### Known issues
- The connect-time contact load can hang (red sync bar stuck) if a contact frame is
  lost — there's no timeout/watchdog yet (#86); reconnect to clear it.
- Companion message-sync may miss public history after a long offline gap (#91); a
  firmware-side fix is in progress.

## [1.1.2-beta.3] - 2026-06-24

### Added
- Diagnostic logging of the Observer broker-pool fetch lifecycle (request sent,
  header count, completed with N brokers + timing, or failed with the reason) to
  the shared log, so a Share-logs capture shows in plain text whether a pool load
  succeeds or stalls (#108).

## [1.1.2-beta.2] - 2026-06-24

### Fixed
- Observer broker pool no longer falsely reports "the device did not finish
  sending it" on large pools — the broker-list GET now uses an inactivity
  watchdog re-armed on each frame, so a pool that streams over several seconds
  completes instead of timing out at a fixed deadline (#103).

## [1.1.2-beta.1] - 2026-06-24

First public beta.

### Added
- Observer config + MQTT broker editor: field-at-a-time SET with enabled-last
  activation, honest enable/disable that verifies the device actually applied the
  change, and broker runtime-state + resolved-default hints (#80, #89, #93).
- Cross-platform file logging to a rotating file under the app support directory,
  with "Open logs folder" (desktop) / "Share logs" (mobile) on the log screen (#97).
- Friendlier repeater path-hash labels (#90).
- Self-contained Windows packaging that bundles the VC++ runtime so the zip runs on
  a clean machine (#96).

### Fixed
- Channel sync advances immediately on a device error instead of stalling on empty
  channel slots (#82).
- The BLE connect handshake retry is capped with backoff so it can't churn the
  connect or starve the contact-list load (#88).

### Known issues
- Companion message-sync may miss public history after a long offline gap (#91); a
  firmware-side fix is in progress.
- MQTT broker / Observer features require the firmware currently in review.

[1.1.2-rc.1]: https://github.com/OffbandMesh/meshcore-client/releases/tag/v1.1.2-rc.1
[1.1.2-beta.1]: https://github.com/OffbandMesh/meshcore-client/releases/tag/v1.1.2-beta.1
