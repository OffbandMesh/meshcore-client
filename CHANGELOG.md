# Changelog

All notable changes to Offband Meshcore. Pre-releases are tagged `-beta.N` / `-rc.N`.

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
