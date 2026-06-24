# Changelog

All notable changes to Offband Meshcore. Pre-releases are tagged `-beta.N` / `-rc.N`.

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
- The connect-time contact load can hang (red sync bar stuck) if a contact frame is
  lost — there's no timeout/watchdog yet (#86); reconnect to clear it.
- MQTT broker / Observer features require the firmware currently in review.

[1.1.2-beta.1]: https://github.com/OffbandMesh/meshcore-client/releases/tag/v1.1.2-beta.1
