# Windows distribution, logs, versioning, signing — notes (2026-06-23)

Reference for shipping the Offband Meshcore Windows desktop build. Answers four
questions raised before the first `feat/64` Windows compile.

## 1. Installer / short-term distribution

A Flutter Windows release is a **folder**, not a single exe:
`build/windows/x64/runner/Release/` = `offband_meshcore.exe` + `flutter_windows.dll`
+ plugin DLLs + `data/` (`app.so`, `flutter_assets/`, `icudtl.dat`). The exe will
**not** run on its own — it needs the whole folder.

**Short-term (zero tooling):** zip the entire `Release/` folder → user extracts →
runs the exe. This is effectively what we do now (running a copied exe).
- Caveat: a truly clean machine may need the **MSVC runtime** (VC++ redistributable).
  Present on most Win10/11; bundle the redist or note it if a tester hits a DLL error.
- Optional polish without an installer: a **self-extracting zip** (7-Zip SFX) so
  the user double-clicks one .exe that unpacks + can auto-launch.

**Real installers, when ready (rough effort):**
| Option | Effort | Notes |
|---|---|---|
| **MSIX** (`msix` Dart pkg) | Low | `dart run msix:create` packages `Release/` → `.msix`; clean install/uninstall; self-sign or CA-sign; Store-ready. Easiest path, ties in signing. |
| **Inno Setup** | Low–Med | Free; short `.iss` script → familiar `setup.exe`. Most control over UX/shortcuts. |
| **MSI / WiX** | High | Enterprise/group-policy deployment. Overkill for us now. |

**Recommendation:** zip the folder for testing now; **MSIX** when we want a clean
install + signing in one step (or Inno Setup if we want a traditional setup.exe).

## 2. Where log files go (today: nowhere)

There are **no log files on disk.** Logging is two in-app, in-memory ring buffers:
- **BLE/frame debug log** — `BleDebugLogService`, **500-entry** ring, Copy-to-clipboard
  (the "RX CODE_192 …" dumps). Captures every transport (BLE/USB/TCP).
- **App debug log** — `AppDebugLogService`, structured app messages.

`debugPrint` goes to stdout, which a **double-clicked release exe has no console for**,
and is largely stripped in release mode anyway. So on a release Windows build the
**only** diagnostics are the in-app log viewers (copy/paste).

**Gap for desktop + real users:** no findable log file for support. If we want one,
add a small file logger writing to `getApplicationSupportDirectory()` →
`%APPDATA%\app.offband.meshcore\logs\` on Windows (rotating, capped). Small task;
worth it before non-technical users are on desktop. (Filed as a follow-up if wanted.)

## 3. Versioning — current state + the gap

- **pubspec:** `1.1.1+18` (feat/64 == dev).
- **Tags present:** `v1.0.0`, `v1.1.0-rc.1/2/3`, `v1.1.2-ble-test`, `v1.1.2-queuediag`
  (+ old upstream `Alpha*`). The `observer-g2-rc8/rc9` GitHub pre-releases I made this
  session are remote-only tags (not semver).
- **The gap (honest):** I have **not** been versioning per SAFELANE §Versioning.
  - This session's commits (#82, #88, #89, #90, #93) did **not** bump pubspec.
  - rc8/rc9 APKs shipped as `+28`/`+29` via `--build-number` overrides, so the
    pubspec build number (`+18`) lags what shipped.
  - Tags already point at **1.1.2** but pubspec still says **1.1.1** — inconsistent.

**Cleanup proposal:**
1. Decide the marketing version for this batch. Tags imply **1.1.2** — bump pubspec
   to `1.1.2+30` (next build after the +29 that shipped).
2. Going forward: bump pubspec **in the milestone commit** and tag `vX.Y.Z`
   (or `-rc.N`) — stop relying on `--build-number` without a matching pubspec bump.
3. Or wire build-time stamping (`git rev-list --count HEAD`) for the build number so
   it can't drift (CLAUDE.local notes this as preferred).

## 4. Windows code signing

Unsigned exe **runs**, but SmartScreen shows "Windows protected your PC / Unknown
publisher" → user clicks **More info → Run anyway**. Annoying, not blocking.

**Cert options (separate from our Android keystore):**
| Cert | Cost | SmartScreen |
|---|---|---|
| **Self-signed** | free | warns unless the user installs/trusts the cert first (OK for known testers; MSIX sideload trusts it once) |
| **OV** (Sectigo/DigiCert…) | ~$100–300/yr | removes "unknown publisher"; reputation builds with downloads over time |
| **EV** (+ hardware token/HSM) | ~$300–600/yr | **instant** SmartScreen trust, no warning day one |

**Signing mechanics are easy** (`signtool sign /fd SHA256 /f cert.pfx ...`, or the
`msix` package signs for you). The cost/effort is **getting a trusted cert** (CA
identity verification + annual fee + an EV token if EV).

**Do we bother?**
- **Short-term (you + a few testers):** No. The one-time "Run anyway" is fine.
- **Public release:** Yes — at least an **OV** cert (or **EV** for zero-warning).
