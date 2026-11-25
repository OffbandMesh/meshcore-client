# Feature PLAN: send logs to Offband

| | |
|---|---|
| **Feature** | [#1190](https://github.com/OffbandMesh/meshcore-client/issues/1190) · Citadel `meshcore-open-oe5` (plan) |
| **Serves** | Standalone. Makes every bug report arrive with its log. |
| **Status** | Draft. Approved when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-11-25 |

## At a glance

- **What:** a **Send to Offband** button that redacts, encrypts and uploads the app's logs, opens a private intake issue with a short reference code, and pings your radio.
- **Why now:** users must export a log and then email or attach it. Most don't, so most bugs arrive without one.
- **How:** six Epics.
  - A: a Cloudflare intake service.
  - B: the log package and a password and PIN redactor.
  - C: the encrypted upload and its screen.
  - D: an offer to send after a crash, ANR or unexpected exit.
  - E: your one-command pull tool.
  - F: the privacy policy and store disclosures.
- **Done when:** a user taps Send and gets a code. You get a radio ping and an issue, and `offband_logs.py pull <code>` leaves a decrypted, unpacked log in `debug_logs/`. offband-prod is untouched by uploads.

## 1. Diagnosis

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | Logs leave the app only by Share (mobile), Save As (desktop) or download (web). | `lib/utils/log_export.dart` | The user has to email the file or attach it somewhere. That's the step that loses the log. |
| 2 | Every frame in and out is written to the log file as raw hex, with no redaction. | `BleDebugLogService.logFrame` writes `frame.map(...toRadixString(16))` for every frame; the owner's Windows log shows `TX CMD_REMOVE_CONTACT 0f 73 60 ...` | Raw frames are what diagnosis runs on (the #1028 reply race was found from them). They also carry passwords and PINs, and today's Share sends those too. |
| 3 | Some frames carry passwords and PINs. | `meshcore_protocol.dart`: `cmdSendLogin` 26 (repeater and room password), `cmdSetDevicePin` 37; Wi-Fi config sub-codes (#837); CLI text such as `password ...`. Channel keys (`cmdSetChannel` 32, `respCodeChannelInfo` 18) also appear, and stay: they're needed for diagnosis (#1128), and the file is encrypted to the owner. The radio's private key appears in `cmdExportPrivateKey` 23, `respCodePrivateKey` 14 and `cmdImportPrivateKey` 24 (choice 4). | Blanking only passwords and PINs keeps the log fully useful. B1 confirms the full list. |
| 4 | Android exit records (crash and ANR) are already captured and exported. | `AppExitInfoService.traceFiles()` used by `log_export.dart` (#906) | D can offer to send them on the next launch. |
| 5 | The radio notify relay is public at `https://notify.offband.org/notify`, behind Cloudflare, with a bearer token. | `scripts/notify.py` (`DEFAULT_URL`, `Authorization: Bearer`); live since standards#476 | The intake can ping your radio with no tailnet change and nothing new on offband-prod. |
| 6 | offband.app is a Cloudflare zone, and I hold a Cloudflare API token. | Pages deploys (`deploy-web.yml`); `CLOUDFLARE_API_TOKEN` | The Worker, its route and the R2 bucket can be set up through the API. Workers and R2 permissions on that token are not yet confirmed. |

## 2. Scope

**In:**
- A Cloudflare Worker on `logs.offband.app` and a private R2 bucket. A new private repo, `OffbandMesh/log-intake`, holds the Worker, its tests and the intake issues.
- A radio ping for each upload, rate-limited so a burst becomes one ping with a count.
- Retention: an upload is deleted 30 days after you have seen it (pulled it, or closed its issue), and never while unseen. Unseen uploads are re-pinged weekly.
- A redactor that blanks passwords and PINs and keeps every frame's code, length and other bytes, channel keys included. It also applies to the existing Share/Save.
- Encryption on the device with Offband's public key. HTTPS in transit on top.
- The Send to Offband screen on every platform (Android, iOS, Windows, macOS, Linux, web), with a consent text, the reference code and Copy.
- After a crash, an ANR, an unhandled error or an exit while in the foreground: on the next launch, the app offers Send, Not now or Don't ask again. A setting, **off by default**, sends without asking.
- `tools/logs/offband_logs.py`: `keygen`, `list`, and `pull <code>`, which downloads, decrypts, unpacks, marks the upload seen and comments on its issue.
- The privacy policy on offband.org, Play Data Safety and the App Store privacy labels.

**Out:**
- Anything on offband-prod. Uploads never reach it.
- Native crash symbolication (separate: #931, `--split-debug-info`).
- Sending logs without the user's action, unless the user turns on the setting.

## 3. Epics

Tasks are 3 to 4 points. Each Epic ends with a verification task and gets one PR.

### Epic A: intake on Cloudflare ([#1191](https://github.com/OffbandMesh/meshcore-client/issues/1191))

| Task | Pts |
|---|---|
| **A1 · Repo, bucket and Worker skeleton:** create the private `OffbandMesh/log-intake`, the private R2 bucket (no public access) and the Worker route on `logs.offband.app`, all through the Cloudflare API. Worker tests run in its CI. | 3 |
| **A2 · Upload endpoint:** one `POST`. It rejects a body over the size cap (25 MB) or one that doesn't start with the format header, and applies a per-IP rate limit. It stores the body under a random name and returns a reference code (`OB-` plus 5 characters, no look-alike letters). There is no read, list or delete endpoint. Tests cover each rejection. | 4 |
| **A3 · Intake issue and radio ping:** open an issue in `log-intake` with the code, platform, app version and the user's optional note. Ping the relay, with at most one ping per 10 minutes; a burst becomes one ping with a count. A failure is retried by A4 and never drops the upload. | 3 |
| **A4 · Retention job:** a daily scheduled run. It deletes an upload 30 days after it was seen, and keeps it if it can't tell. Unseen uploads older than 7 days are re-pinged weekly. Tests use an injected clock. | 3 |
| **A5 · Epic verification:** a live upload from curl returns a code, opens an issue and pings the radio. Oversized and junk bodies are refused. | 1 |

### Epic B: log package and password and PIN redactor ([#1192](https://github.com/OffbandMesh/meshcore-client/issues/1192))

| Task | Pts |
|---|---|
| **B1 · Inventory:** classify every command, response and push code in `meshcore_protocol.dart`, and every Offband sub-code, as carrying a password or PIN (with the byte ranges) or not. A test fails when any code is unclassified, so a new command can't ship unreviewed. | 3 |
| **B2 · Redactor:** blank password and PIN bytes in logged frames and in CLI text (`password`, `set pin`, Wi-Fi), plus the private key if choice 4 says so. Everything else, channel keys included, is kept byte for byte. Tests cover every redacted code, plus unchanged frames for the rest. | 4 |
| **B3 · Package builder:** all log files, the Android exit traces and a manifest (app version, commit, platform, OS, radio firmware and caps), redacted and zipped. The existing Share/Save goes through it too. | 3 |
| **B4 · Epic verification** | 1 |

### Epic C: encrypt, upload and the Send screen ([#1193](https://github.com/OffbandMesh/meshcore-client/issues/1193))

| Task | Pts |
|---|---|
| **C1 · Encryption:** ephemeral X25519, HKDF-SHA256 and AES-256-GCM, with a format header carrying a key id, so the key can be rotated. The app holds only Offband's public key. Each upload makes a one-time key pair and puts its public half in the header; the owner's private key plus that half rebuilds the key, so the owner never needs anything from the user. Uses the vetted Dart `cryptography` package, not hand-built primitives. Test vectors are shared with E, so Dart output decrypts in Python. | 4 |
| **C2 · Upload client:** HTTPS POST and the code it returns. Every failure (no network, refused, too big, rate-limited) stays on screen with its reason, and the package is kept for Retry. | 3 |
| **C3 · Send to Offband screen:** next to Share on both log screens. The consent text says what's included, including message text and radio frames, with passwords and PINs removed, that only Offband can read it, and how long it's kept. There's an optional note. The result is the code with Copy. New strings are English-only, and `untranslated.json` is committed. | 4 |
| **C4 · Web:** upload the in-memory log; the Worker allows CORS from offband.app and dev.offband.app only. | 2 |
| **C5 · Epic verification:** a test build on Android and Windows sends, and the code matches the issue. | 1 |

### Epic D: offer to send after a failure ([#1194](https://github.com/OffbandMesh/meshcore-client/issues/1194))

| Task | Pts |
|---|---|
| **D1 · Detection:** a new Android crash or ANR exit record; an unhandled Dart error (`FlutterError.onError`, `PlatformDispatcher.onError`); and a run marker that wasn't cleared while the app was in the foreground. An exit while in the background is the OS reclaiming memory, not a failure. Tests cover each. | 4 |
| **D2 · Prompt and setting:** on the next launch: Send, Not now, Don't ask again. The setting "Send crash logs automatically" is off by default. | 3 |
| **D3 · Epic verification:** a forced crash and a forced ANR each bring up the prompt on hardware. | 1 |

### Epic E: owner pull tool ([#1195](https://github.com/OffbandMesh/meshcore-client/issues/1195))

| Task | Pts |
|---|---|
| **E1 · Keys:** `offband_logs.py keygen` writes the private key to `~/.secrets/` and prints the public key, which goes into the app. You store the private key in Bitwarden. Without it, no upload can ever be read again. | 2 |
| **E2 · list / pull:** `list` shows unseen uploads. `pull OB-XXXXX` downloads with an R2 read token, decrypts, unpacks into `debug_logs/OB-XXXXX/`, marks the upload seen (which starts the 30-day clock) and comments on its issue. A failed decrypt marks nothing. Tests use C1's vectors. | 4 |
| **E3 · Epic verification:** pull the upload from C5. | 1 |

### Epic F: privacy and store disclosures ([#1196](https://github.com/OffbandMesh/meshcore-client/issues/1196))

| Task | Pts |
|---|---|
| **F1 · Privacy policy:** an offband.org section on diagnostics. It covers: sent only when the user chooses, or turns on automatic crash logs; encrypted in transit and at rest; readable only by Offband; deleted 30 days after review, or on request by reference code. | 2 |
| **F2 · Store disclosures:** Play Data Safety ("Crash logs" and "Diagnostics": optional, encrypted in transit, deletable) and the App Store privacy labels to match. Done through an API where one exists; otherwise you paste text I give you. | 2 |
| **F3 · Epic verification** | 1 |

## 4. Order and dependencies

- **A and B first**, in parallel. They share no files.
- **C** needs A's endpoint and B's package. **E** needs A's bucket and C1's format. **D** needs C. **F** comes last, so the texts describe what was built.
- **#1186** (ChartreuseGate, unmerged) also edits `lib/main.dart`, for lifecycle logging. D1 coordinates with it over Agent Mail and rebases on it if it merges first.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | All coding, pushes and PRs for Epics A to F, back to back. Creating `OffbandMesh/log-intake`, the R2 bucket, the Worker and its route through the Cloudflare API. | One approval for the chain. |
| **Merges** | 6, held and brought to you together at the end. | One PR per Epic. |
| **Epic verification** | Owner, at the end. | Live upload, radio ping and hardware prompts can't be vouched for by a test command alone. |
| **Owner steps during the run** | (1) Store the private key in Bitwarden (E1). (2) Create a fine-grained GitHub token, Issues write on `log-intake` only, for the Worker (A3). (3) If the Cloudflare token refuses Workers or R2, add those permissions; I'll name the refused call. (4) Paste the store disclosures if no API covers them (F2). (5) Choice 3, if you pick a dedicated relay token. | Things I can't or shouldn't do myself. |
| **Stops** | Any **stop** in section 6. A refused API call I can't work around. | |
| **Flash** | None | |

```grant-terms
{
  "epic_chain": [1191, 1192, 1193, 1194, 1195, 1196],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 6, "basis": "One PR per Epic: A in OffbandMesh/log-intake, B to E in meshcore-client, F in offband-site plus the store texts." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

## 6. Can't-tell branches

| Where | Can't tell what | Does |
|---|---|---|
| Worker upload | Body over the cap, or no format header | **stop**: refuse with 413 or 400 |
| Worker upload | R2 write fails | **stop**: 5xx; the app keeps the package and offers Retry |
| Worker intake | Issue creation or ping fails | **stop**: the upload is kept, the code is still returned, A4 retries, and the failure is recorded |
| Retention job | Whether an upload was seen (marker or GitHub unreachable) | **stop**: keep it; never delete on doubt |
| App encrypt | Public key missing or malformed | **stop**: no upload, persistent error |
| App upload | Network, TLS or server error | **stop**: persistent error with the reason, package kept, Retry |
| Redactor, at build time | A protocol code not classified | **stop**: CI test fails |
| Redactor, at runtime | A frame code unknown to this build (newer firmware) | **stop**: keep the code and length, blank the payload, mark it "unclassified" (choice 2) |
| Crash detection | Run marker present, last foreground state unknown | **ask**: offer the prompt; the user decides |
| Pull tool | Decrypt or auth tag fails | **stop**: write nothing, mark nothing seen |

No branch proceeds without confirming its condition, so no fail-open grant is needed.

## 7. Verification

- **Named command:** `flutter analyze` and `flutter test` (meshcore-client); the Worker's test suite (log-intake); `python -m pytest tools/logs` (E).
- **Acceptance bar:**
  - Each fix and behavior has a test that fails without it.
  - The redactor's classification test covers every protocol code.
  - C1's vectors decrypt in E.
  - A live end-to-end send from Android and Windows test builds.

## 8. Done when

- Send to Offband on Android, iOS, Windows, macOS, Linux and web returns a code.
- Each upload opens one intake issue and pings your radio. Bursts are batched.
- `offband_logs.py pull <code>` leaves a decrypted, unpacked log in `debug_logs/`, with passwords and PINs blank and every other byte intact.
- After a forced crash or ANR, the next launch offers to send.
- An upload is gone 30 days after you've seen it, and stays while unseen.
- The privacy policy, Data Safety and App Store labels say so.

## 9. Your choices

| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Where do intake issues go? | A private `OffbandMesh/log-intake` repo: user notes and device details stay private, and spam never reaches the public tracker. | The public meshcore-client repo, on board #2. | ⭐ A. You move an intake issue into meshcore-client when it becomes a bug. | |
| 2 | A frame code this build doesn't know, from newer firmware? | Blank its payload, keep code and length. Safe, loses that frame's detail. | Keep it raw. Full detail, but it might carry a password we haven't classified. | ⭐ A. The next release classifies it. | |
| 3 | Relay token for the Worker? | A dedicated token, revocable on its own. Needs a small, governed offband-infra change on the relay. | Reuse the existing `NOTIFY_TOKEN`. Nothing changes on offband-prod, but revoking it also cuts off session pings. | ⭐ A | |
| 4 | The radio's private key, in an export or import frame? | Blank those 64 bytes and keep the rest of the frame. The key lets anyone impersonate that user's node and read their DMs, and its bytes tell a diagnosis nothing. | Keep it. The file is encrypted to you, so only you or someone with your private key could read it. | ⭐ A | |

Owner decision 2026-11-25: channel keys are **not** redacted. Only passwords and PINs are, plus the private key if choice 4 is A.

## 10. Carried-in work

| Item | Goes to |
|---|---|
| Today's Share/Save sends passwords and PINs in raw frames (findings 2 and 3) | Fixed by B3: Share goes through the redactor |
| #1186 lifecycle logging (ChartreuseGate) | D1 coordinates on `lib/main.dart` |

When this plan merges, each Task gets a GitHub issue under its Epic and a Citadel task, per canon.
