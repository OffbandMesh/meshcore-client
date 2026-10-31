# Feature PLAN: publish Offband Meshcore to the Apple App Store

| | |
|---|---|
| **Feature** | [#200](https://github.com/OffbandMesh/meshcore-client/issues/200) · Citadel `meshcore-open-in0` |
| **Serves** | Standalone. Sibling of the Google Play release (#159/#160), built on the CI matrix of #312. |
| **Status** | Owner-approved 2026-10-27 ("Plan approved. We'll adapt as we learn more."). In force when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-10-31 |

## At a glance

- **What:** Offband Meshcore on the App Store for iPhone, every territory except France, under the owner's Individual account.
- **Why now:** iOS users have no way to run Offband. The web build needs Web Bluetooth, which no iOS browser has, so the App Store is the only path.
- **How:** Epic A builds the Windows signing toolchain and proves its output imports on a Mac runner; Epic B builds the signed IPA and TestFlight upload lane; Epic C prepares everything App Review reads; Epic D is the owner's hardware pass, the demo video and the submission.
- **Done when:** the app is approved and live, the listing's privacy label matches C2, and the owner's hardware pass on family iPhones and iPads passed.

## 1. Diagnosis

Research is on [#958](https://github.com/OffbandMesh/meshcore-client/issues/958), every claim cited there. `[verified]` means read this cycle from the source named; `[hypothesis]` means a reading that a task below has to prove or disprove.

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | The `ios` CI job only compiles. | `flutter build ios --release --no-codesign` (`build.yml:134`) `[verified]` | Green proves nothing installable. Everything below the compile is unbuilt. |
| 2 | The `ios` job writes no Giphy define. | No `dart_defines.json` step in `build.yml:116-135`, unlike android, linux, web and windows `[verified]` | A signed build made the same way would ship with a broken GIF picker. |
| 3 | iOS bundles native assets without the flag. | linux, macos and windows run `flutter config --enable-native-assets` (#445); `ios` does not, and run 41171197215 on Flutter 3.44.1 still produced `sqlite3.framework` and `llamadart.framework` `[verified]` | The first draft's hypothesis that the flag was needed was wrong. The risk of a build that compiles but lacks them stays, so an assertion guards every build. |
| 4 | The project targets iPhone **and** iPad. | `TARGETED_DEVICE_FAMILY = "1,2"` (`project.pbxproj:438`) `[verified]` | Contradicts the iPhone-only decision, and would require iPad screenshots. iPhone-only apps still run on iPad. `[hypothesis: standard iPadOS compatibility mode]` |
| 5 | Signing is Automatic with no team. | `CODE_SIGN_STYLE = Automatic`, no `DEVELOPMENT_TEAM` (`project.pbxproj:468`) `[verified]` | The signed lane must supply manual signing at build time. |
| 6 | The iOS bundle id differs from Android's. | Apple refused `app.offband.meshcore` as not available, and the owner's team did not hold it `[verified: owner screenshots 2026-10-31]`. The owner created the app as `app.offband.meshcore.ios` | The Xcode project moves to the new id. Android stays `app.offband.meshcore`. Who holds the original is unknown. |
| 7 | No location purpose string is needed. | No location plugin in `pubspec.yaml` or `lib/` `[verified]` | Map positions come from radios. Bluetooth and camera strings are present. |
| 8 | Signed releases already run on `v*` tags and manual dispatch, with secrets scoped to one job behind a required reviewer. | `release-signed.yml`: only `android` uses Environment `release-signing`; `release` needs `[android, windows, linux]` `[verified]` | iOS copies this pattern in its **own** Environment, and must not be able to block the GitHub release. |
| 9 | App Store Connect API access needs its own approval. | "The Account Holder must request access... reviewed and approved on a case-by-case basis." Key downloadable once. `[verified]` | A separate owner wait, requested on day one after enrollment. |
| 10 | Apple documents `openssl` as a CSR source, and Flutter documents `altool` upload with an API key. | Apple CSR page; docs.flutter.dev/deployment/ios `[verified]` | The Windows-only path is real. Apple's upload page lists Developer among the roles that can upload `[verified]`; that a team key with that role uploads through `altool` `[hypothesis: B5 proves it]`. Key size `[hypothesis: RSA 2048]`; `.p8` location for `altool` `[hypothesis]`. |
| 11 | OpenSSL 3 writes `.p12` files older macOS tooling has refused. | Owner's box has OpenSSL 3.5.7 via Git for Windows `[verified]`; import compatibility `[hypothesis: untested]` | Must be proven on a runner, and can be, with a throwaway fixture, before enrollment. |
| 12 | With France excluded, Apple needs **no** export document. | Standard algorithms not from Apple's OS need only the French declaration, and only for France `[verified]` | No CCATS, no French form. France is out by owner decision (#957). |
| 13 | The shipped binary likely falls outside the US EAR. | 15 CFR 734.3 Note plus 742.15(b): public source, standard crypto, no notification `[verified text]`; the reading `[hypothesis]`, an engineer's reading and not legal advice | Holds only while **every** binary is built from public source. A standing rule below. Whether to have counsel confirm it is the owner's call. |
| 14 | `ITSAppUsesNonExemptEncryption` cannot be set safely in advance. | The questionnaire appears only inside App Store Connect `[verified: no public text]` | Answer it once on the first build, then pin Info.plist to the outcome. |
| 15 | The privacy label declares CoreScope, and the other hosts are likely not "collection". | Apple's "collect" needs retention by you or by vendor code in the app; Offband's calls are plain HTTP with no vendor code `[verified definitions]`, reading `[hypothesis]` | CoreScope is declared per choice 2, so the listing will not read "Data Not Collected". C2 settles the rest host by host. |
| 16 | The privacy policy has five iOS gaps. | `offband-site/content/privacy.md`: no CoreScope, no GitHub raw, Android-only deletion and permissions, no support page `[verified]` | Lives in the `offband-site` repo, so it is a dependency, not a task here. |
| 17 | App Review asks for hardware evidence. | "If features require... specific hardware, be prepared to provide a demo video or the hardware." `[verified]` | A demo video recorded from the TestFlight build on a family iPhone. |
| 18 | A public TestFlight link is external testing. | "When you add the first build... it gets sent to App Review... only for the first build." `[verified]` | One beta review before family devices can install. |

## 2. Scope

**In:**
- A PowerShell script that does the owner's certificate work on Windows, with `openssl`.
- A reusable signed-iOS workflow, called by a manual TestFlight dispatch and by the `v*` tag release.
- The four CI gaps in finding 1 to 5, closed and proven.
- The App Store submission package: export answer, privacy answers, review notes, listing copy, screenshot spec, demo video script.
- The owner's hardware pass, the video, and the submission through the first review.

**Out:**
- France (owner decision, #957). Adding it later is a separate decision.
- An iPad listing. iPads remain a TestFlight test surface only.
- In-app purchases, Mac App Store, Mac Catalyst.
- Codemagic. Recorded fallback on #959, taken up only with evidence that GitHub runners cannot sign.
- Any change under `lib/` or Android. If the hardware pass finds an app defect, it gets its own issue.
- The privacy-policy and support-page edits. They belong to `OffbandMesh/offband-site`; see section 10.

## 3. Epics

Epic issues, created 2026-10-27 on approval and before this PR, so `epic_chain` is never empty at merge (the #962 lesson): [#1012](https://github.com/OffbandMesh/meshcore-client/issues/1012) A, [#1013](https://github.com/OffbandMesh/meshcore-client/issues/1013) B, [#1014](https://github.com/OffbandMesh/meshcore-client/issues/1014) C, [#1015](https://github.com/OffbandMesh/meshcore-client/issues/1015) D, all sub-issues of #200, Citadel `meshcore-open-zgf`, `-s1b`, `-ywm`, `-3gp` chained A to D. #959 is a child of B; #960 and #961 are children of D.

### Epic A: the Windows signing toolchain, proven on a Mac runner

Buildable and testable **before enrollment**, because its proof uses a throwaway certificate.

| Task | Pts |
|---|---|
| **A1 · Prove the trap first:** a PR-triggered CI job on `macos-latest` that generates a **throwaway self-signed** certificate on the runner, packs it as both the OpenSSL 3 default and the legacy `.p12`, and imports into a temporary keychain. The legacy one must import with key and certificate paired; a wrong password must be refused, so the check is shown able to fail; the default's result is recorded. **Changed from the first draft's committed fixture:** generating on the runner means no private key, even a dummy one, ever lands in this public repository. | 3 |
| **A2 · `tools/ios-signing/ios-signing.ps1`,** PowerShell only, calling `openssl` from Git for Windows. `new-csr` writes key and CSR to `%USERPROFILE%\.offband-ios\`, or the folder given with `-WorkDir`, outside the repo. `make-p12` builds the legacy-format `.p12` from Apple's `.cer`, with a generated password it never prints. `set-secrets` base64-encodes each file and pipes it into `gh secret set --env apple-signing`. Run end to end by me against the fixture before the owner sees it. | 4 |
| **A3 · The `apple-signing` Environment** with the owner as required reviewer, matching `release-signing`. A repository setting, so it is a Tier-2 step: named rollback `gh api -X DELETE repos/OffbandMesh/meshcore-client/environments/apple-signing`, owner's word first, verified after. | 1 |
| **A4 · Owner runbook** for rounds 2 and 3 (section 5): paste-ready PowerShell, what each line does, what he will see. No step asks him to type text. | 2 |
| **A5 · Epic verification:** A1 green on the legacy `.p12` and refusing a wrong password; the default format's result recorded, whichever way it goes; the script's output imports. | 1 |

### Epic B: the signed IPA and TestFlight lane

Needs the real certificate, profile and API key, so it waits on owner rounds 2 and 3.

| Task | Pts |
|---|---|
| **B1 · Close the compile job's gaps** in `build.yml`'s `ios` job and the project: `TARGETED_DEVICE_FAMILY = 1`, Giphy define written. Plus an assertion that the built `.app` actually contains the `sqlite3` and `llamadart` frameworks, shown able to fail on every run against an empty app, because a build without the flag still contains them (finding 3). | 3 |
| **B2 · `ios-signed.yml`,** a `workflow_call` workflow in Environment `apple-signing`: decode secrets (stop if any is empty), temporary keychain, install profile, write `ExportOptions.plist` (App Store Connect, manual signing, team, profile), `flutter build ipa` with `--build-name` from pubspec and `--build-number` per choice 1, the framework assertion again on the IPA, a `codesign` check that the app inside the IPA is signed by the Apple Distribution certificate (made to fail first against a wrong name, matching the Android fingerprint pin), then `altool` validation and upload, both always run. Keychain and key files removed with `if: always()`. | 4 |
| **B3 · Callers:** `testflight.yml` on `workflow_dispatch`, and an `ios` job in `release-signed.yml` after `gate`. **`release` does not depend on it**, per choice 4. Neither workflow gains a `pull_request` trigger. | 3 |
| **B4 · Read `man altool` on the runner** for the `.p8` location, failure reporting, and the current validate and upload subcommands (`--validate-app`, and whether `--upload-app` or `--upload-package` is current), and parse the upload output so an error that exits 0 still fails the job. | 2 |
| **B5 · Epic verification:** one build uploaded from the Epic branch and visible in App Store Connect with the expected version and build number. The first run uses a `push` trigger keyed to this Epic's exact branch name, inert anywhere else. `apple-signing` allows only branch `main` and tag `v*`, so it would refuse that branch, and a manual dispatch from it too: the owner adds that one branch to the Environment for B5 and removes it after, verified by API read-back each way. After merge, `testflight.yml` is dispatched from a `v*` tag or `main`. | 2 |

### Epic C: everything App Review reads

| Task | Pts |
|---|---|
| **C1 · Export compliance:** the owner answers the questionnaire once on B5's build; the answers and outcome are recorded on #958; `ITSAppUsesNonExemptEncryption` is set in `ios/Runner/Info.plist` to match. | 2 |
| **C2 · `APP-PRIVACY.md` beside this plan:** the exact answers to enter in App Store Connect, host by host, with Apple's definition quoted for each, and CoreScope per choice 2. | 2 |
| **C3 · Review notes and demo video script:** what the app is, that it needs a MeshCore radio over Bluetooth, the on-device translation model (about 45 MB) so it is not mistaken for dead weight, and the shot list for the video. | 3 |
| **C4 · Listing copy and screenshot spec** under the copy policy: no promotional terms, no ALL-CAPS beyond the brand, no em-dash. Screenshot sizes read from Apple's current specification at the time, not recalled. | 3 |
| **C5 · Epic verification:** every App Store Connect field in C1 to C4 filled, the external TestFlight group and public link created, beta review submitted. | 1 |

### Epic D: Integration Testing

| Task | Pts |
|---|---|
| **D1 · Hardware pass, owner-run** on family iPhones and iPads over the public link. Positive: BLE pairing and connect, channel and direct send and receive, contact sync, map, QR scan, notifications, staying connected in the background. Negative: Bluetooth permission denied, radio switched off, out of range, a disconnect mid-send. Each with an expected result written before the run. | 4 |
| **D2 · The demo video,** recorded from the TestFlight build on a family iPhone with a radio, to C3's shot list. | 2 |
| **D3 · Submission and the first-review loop.** Submitting is a publish action: the owner's explicit word first. Each rejection becomes an issue with Apple's text quoted. | 3 |
| **D4 · `OUTCOMES.md`:** a plain-language summary, what shipped, the evidence, what is left. | 1 |

## 4. Order and dependencies

A first, and it does not wait on Apple: its proof is a fixture. B waits on owner rounds 2 and 3. C1 needs B5's build. D needs C5.

File overlap: B1 and B3 both touch workflows (`build.yml`, `release-signed.yml`); B2 adds `ios-signed.yml`; C1 touches `Info.plist`; B1 touches `project.pbxproj`. All sequential inside the chain, so no two tasks edit one file in parallel.

**Standing rule from finding 13:** every shipped binary is built by CI from this public repository. A closed-source dependency that carries its own encryption would break the export reading and has to come back to the owner first.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Building Epics A to D, one PR per Epic, and the Tier-2 Environment step in A3 on the owner's word. | Four Epics, four PRs. |
| **Merges** | 4 | One per Epic. |
| **Epic verification** | Owner approves each Epic's PR. | Signing credentials and a public store listing. Each PR should be looked at. |
| **Owner steps during the run** | Five rounds, below. | Everything Apple ties to his account is his. |
| **Stops** | Any missing secret, failed import, failed upload, or a review rejection. | Each is loud and named, never retried in a loop. |
| **Flash** | None. | No firmware. |

**Owner rounds**, each one consolidated, paste-ready message:

| Round | When | What |
|---|---|---|
| 1 | Done 2026-10-30 | Enrollment in the Apple Developer Program (#957). |
| 2 | Done 2026-10-31 | Request App Store Connect API access; register the `app.offband.meshcore.ios` identifier; create the app record; availability with France unchecked; declare non-trader. |
| 3 | Done 2026-10-31 | Generate the team key; run the script's `new-csr`; create the Distribution certificate; run `make-p12`; create the App Store profile; run `set-secrets`. |
| 4 | First TestFlight build | Add the Epic B branch to `apple-signing` for B5, then remove it. Answer the export questionnaire; enter the privacy answers from C2; set up the public link. |
| 5 | Beta review passed | The hardware pass, the video, and the word to submit. |

```grant-terms
{
  "epic_chain": [1012, 1013, 1014, 1015],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 4, "basis": "one merge per Epic: A signing toolchain, B signed IPA and TestFlight lane, C App Review package, D Integration Testing; tasks are commits on each Epic branch, so there is no per-task PR" },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

`epic_chain` holds Epics A to D, #1012 to #1015, in order.

**Basis for the expiry,** stated plainly: 168 hours is the maximum, and it is probably **not enough**. Enrollment review, API approval and beta review are all Apple's clock. Expect one re-mint when Epic B starts.

## 6. Can't-tell branches

| Where | Can't tell what | Does |
|---|---|---|
| Any signed step: a secret is empty or absent | whether the run has credentials | **stop**, naming the secret, never skipping signing or upload |
| `.p12` import fails | whether the certificate is usable | **stop** |
| Profile UUID or name cannot be read | which profile to sign with | **stop** |
| The built `.app` or IPA lacks a native-asset framework | whether storage and translation work | **stop** |
| `altool` output contains an error, whatever its exit code | whether the validation passed or the upload landed | **stop** |
| The IPA's signing identity cannot be read or is not the Distribution certificate | what was signed | **stop** |
| Apple rejects a duplicate build number | whether this build is new | **stop** |
| `ios-signing.ps1`: `openssl` not found, or a step's output file is missing | whether the step worked | **stop**, printing what was expected and where |
| `set-secrets`: the file to encode does not exist | what would be stored | **stop**, never setting an empty secret |

No branch proceeds. There is deliberately **no** "skip upload" or dry-run input: a switch that lets a release go green without doing its job is the shape of the #904 override, and a TestFlight upload is private and harmless, so the lane proves itself by actually uploading.

## 7. Verification

- **Named command:** `flutter analyze` and `flutter test`, unchanged, plus each Epic's CI run linked in its PR.
- **Acceptance bar:**
  - A1's import check green on the legacy `.p12` and refusing a wrong password, with the default format's result recorded.
  - B2's signing check red against a wrong certificate name, green against the real one.
  - B1's framework assertion red on an empty app, green on the real one.
  - A build in App Store Connect with the expected version and build number.
  - D1's positive and negative cases all at their expected result on a real iPhone.

## 8. Done when

- Offband Meshcore is approved and live on the App Store, iPhone only, every territory except France.
- The seller is the owner's legal name, and no contact details are published (non-trader).
- The privacy label matches C2, and the offband.org policy names every host.
- D1 passed on family devices, and `OUTCOMES.md` is merged.

## 9. Your choices

| # | Question | Option A | Option B | Rec. | Your choice |
|---|---|---|---|---|---|
| 1 | Where does each upload's build number come from? | The CI run number, stamped at build time: always unique, never a commit | The pubspec `+N`, matching Android, but every beta then needs a pubspec commit | ⭐ A | A, using the run **ID**: the two callers each count their own run numbers, so run numbers would collide |
| 2 | CoreScope sends packet hashes to `map.okimesh.org`, a server you help run. Declare it? | Declare nothing | Declare "Other Data, not linked to the user, App Functionality" | ⭐ B, safe to take unread | B |
| 3 | The support URL App Review requires | A small `offband.org/support` page (`offband-site` work) | The privacy page's contact line | ⭐ A | A |
| 4 | Should the GitHub release wait on the iOS upload? | No: an Apple outage cannot block Android and desktop | Yes: all platforms or none | ⭐ A | A |

The owner approved the plan without naming options, so the recommendations stand, recorded on #200 as reversible.

Decided already, not choices: Individual enrollment; seller is the legal name; non-trader; France out; public TestFlight link, never email invites; iPhone-only listing; `support@offband.org` as the Apple Account email; Codemagic as fallback only (#957).

**Alternatives considered but not chosen:**
- **Cloud-managed certificates:** no `.p12` at all, but Apple documents it for the Xcode Organizer workflow, and CI would need a broader-role API key. The owner directed the `openssl` path.
- **Codemagic:** a recorded fallback, not needed while GitHub's macOS runners work.
- **A dry-run upload input:** rejected, section 6.
- **Signing in `build.yml`'s PR job:** rejected. A pull request must never run a job that can read signing credentials, the same rule `release-signed.yml` states.

## 10. Carried-in work

| Item | Goes to |
|---|---|
| Privacy policy: add CoreScope and GitHub raw, iOS deletion and permission text, and the support page from choice 3 | A new issue in `OffbandMesh/offband-site`, needed before C5 |
| Adding France with the French declaration | Not filed; a later owner decision |
| An iPad listing | Not filed |
| The BIS page's inconsistent wording on empty years, if the open-source reading ever fails | #958, only if needed |

When this plan merges, each Epic and Task has a GitHub issue and a Citadel task, per canon.
