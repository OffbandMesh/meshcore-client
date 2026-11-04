# Feature PLAN: Play publishing automation

| | |
|---|---|
| **Feature** | [#1053](https://github.com/OffbandMesh/meshcore-client/issues/1053) · Citadel `meshcore-open-sme` |
| **Serves** | Standalone. Extends the release pipeline (epic #312) and mirrors the iOS lane (#1013). |
| **Status** | Owner approved 2026-11-03 ("Plan approved."). Review fixes applied afterwards (section 12). In force when this PR merges. |
| **Owner** | @Strycher |
| **Last updated** | 2026-11-03 |

## At a glance

- **What:** a tagged release reaches Play through CI. You send it to External (Play's closed testing) or straight to production, and promote from External to production when you're ready. Test builds stay `adb` sideloads.
- **Why now:** a cut takes five manual Play steps.
- **How:** two Epics. API access and the upload tool, then the publish workflow.
- **Done when:** a release reaches External or production from one word to me and one click from you, with no file handling.

### What a cut looks like afterwards

| Step | Today | Afterwards |
|---|---|---|
| Read the release texts, say "tag it" | You | You |
| Approve signing on the run | You | You |
| Bump `+N` in `pubspec` | Me, at the cut | Me, at the cut (unchanged) |
| Get the AAB | Me, into Downloads | Gone. It stays on the GitHub release, where CI reads it. |
| Upload, paste notes, name the release | You | CI, from `play/<version>.txt` |
| Send to External or production | You, in Console | You say "External" or "production at N%", I dispatch it, you approve one click |
| Move from External to production | You, in Console | You say "production at N%", I dispatch it, you approve one click |
| Post to Discord | You | You (unchanged, CI never sends) |

### Things you should know up front

1. **Test builds never touch Play.** Every upload uses a version code forever, so only tagged releases upload, one code per release, as today. Test builds stay `adb` sideloads.
2. **External goes to your whole closed tester list,** after Google's review. Production takes `draft` or a percentage.
3. **Anyone opted in to Internal testing gets only Internal builds.** Google says they aren't eligible for closed or open builds. Nothing will upload to Internal, so anyone already opted in, your phone included, needs to opt out of Internal to get External builds.
4. **The workflow can only be proven on a real release.** It runs only from a `v*` tag, so its live proof is the next cut.
5. **`release-signed.yml` gets one small addition:** a provenance attestation on the AAB, so the publish workflow can prove the file it sends to Play is the one the signed run built. Added after review (section 12).

## 1. Diagnosis

| # | Finding | Evidence | Effect |
|---|---|---|---|
| 1 | No Play API access exists. The only Google credentials are a user login and ADC for reporting. | `gh secret list`, `gcloud auth list`. `CLAUDE.local.md` records that the user token cannot get a Play scope. | A new service account is required. |
| 2 | `release-signed.yml` builds a signed AAB, attaches it to the GitHub release, and stops. | `release-signed.yml` android and release jobs. | Everything after that is manual. |
| 3 | A version code can never be reused, and Play has seen up to 68. | Android docs: "You can't upload an APK to the Play Store with a `versionCode` you have already used." Bucket stats list 64, 65, 67, 68. | Uploading test builds would use up codes. Only releases upload. |
| 4 | The closed testing track already exists and has been used. Open testing never was. | Cuts #214, #265 (1.1.2), #563 (1.5.0-beta.1). #159: "Open testing skipped." | External is that track. |
| 5 | Internal testers receive only Internal builds. | Play help, "Version code requirements." | Item 3 of the up-front list. |
| 6 | Release assets can be replaced after publishing, and a local release-signed build carries the same certificate and version code. Workflow artifacts expire after 7 days. | `release-signed.yml`: `gh release upload --clobber` on re-run, `retention-days: 7`. | A certificate and version code check can't tell the CI build from a local one. Provenance can. |

## 2. Scope

**In:**
- One Google service account, keyless, usable only from CI.
- `tools/play/`: the upload tool and its tests.
- `play-publish.yml`: send a tagged release to External or production, and promote External to production.
- A provenance attestation on the AAB in `release-signed.yml`.
- The cut runbook update.

**Out:**
- Test builds to Play on any track, and internal app sharing. Test builds stay sideloads.
- Open testing.
- Store listing text and screenshots through the API.
- Discord. It stays human-pasted.
- Uploading native debug symbols for named ANR frames. Worth doing next, separately.
- Halting or narrowing a rollout from CI. Console does that in one click.
- Any other change to `release-signed.yml`.

## 3. Epics

### Epic A: API access and the tool

| Task | Pts |
|---|---|
| **A1 · Tool, tests first:** `tools/play/play_release.py`, standard library only. Given the AAB, the tag, a track and a rollout: checks the certificate against the pin `release-signed.yml` uses, checks the bundle's version code matches the tag's `pubspec`, and checks the code is higher than everything on Play unless Play already holds this exact release. Then builds the edit, uploads only if Play doesn't have the bundle, sets the track with the notes, and commits. Track status: `draft` stays `draft`; 100 is `completed`; 10, 25 or 50 is `inProgress` with that fraction, production only. Idempotent: if the track already carries this release at the requested rollout or wider, it reports success and changes nothing, so a re-run after a lost result is safe. It never removes another release from a track, and stops if the target track has a different version mid-rollout. A failed run deletes its uncommitted edit. Tests prove each refusal in section 6 by failing first. | 3 |
| **A2 · Identity:** in the existing `offband-reporting` project, enable the Android Publisher API and create one service account, `play-publisher`, with a GitHub keyless (Workload Identity) pool. Its condition requires all of: this repo's numeric ID, the `play-release` environment, a tag ref starting `refs/tags/v`, and `workflow_ref` naming `play-publish.yml` at that tag. The environment's own deployment policy also allows only `v*` tags. No JSON key is ever created, and no Play credential exists on this machine. **Owner steps:** invite the account in Play Console, limited to this app, with "Release to production, exclude devices, and use Play App Signing" and "Release apps to testing tracks". Confirm the closed track's tester list is still who you want. | 3 |
| **A3 · Epic verification:** a read-only dispatch lists every track and its version codes, which proves the identity works and reads the real track names. Then the negative test: a dispatch from anything but a `v*` tag must be refused. Also settles the provenance check B0 relies on: `gh attestation verify --source-ref` passes for an attested public release at its own tag and fails when given a different tag. | 2 |

### Epic B: the publish workflow

| Task | Pts |
|---|---|
| **B0 · Provenance:** the `android` job in `release-signed.yml` attests the AAB with `actions/attest-build-provenance`. Before anything reaches Play, the publish workflow runs `gh attestation verify` with `--signer-workflow` set to `release-signed.yml`, `--source-ref` set to the tag, and `--deny-self-hosted-runners`. A file swapped onto the release, or built anywhere else, fails. | 2 |
| **B1 · Workflow:** `play-publish.yml`, `workflow_dispatch` only, from a `v*` tag. One `concurrency` group for the whole app, never cancelling a run in progress, so two dispatches can't race on Play's edits. Refuses a tag whose commit isn't on `main`, so a tag pushed onto an unreviewed commit can't publish even if its signing run was approved. Permissions: `contents: read`, `attestations: read`, and `id-token: write` for the keyless token. Inputs: `target` (`external` or `production`) and `rollout` (`draft`, 10, 25, 50 or 100; External takes `draft` or 100). Downloads `app-release.aab` from that tag's GitHub release and runs the tool. New environment `play-release`, you as reviewer. No `pull_request` trigger, no keystore. The first dispatch for a tag uploads; later ones move the same bundle, so External and production get the same bytes. Re-dispatching a higher percentage widens a production rollout. | 3 |
| **B2 · Cut runbook:** the new steps go in `CLAUDE.local.md` and my cut notes, and the AAB download to Downloads is dropped. | 1 |
| **B3 · Epic verification:** static checks at merge. The live proof is the next real cut, through whichever route you choose. The other route is proven the first time you use it. This task stays open until both have run. | 2 |

## 4. Order and dependencies

A, then B. B0 adds two permissions and one step to the `android` job in `release-signed.yml`. The open iOS PR #1042 adds a separate `ios` job to the same file, so B0 rebases over it if it lands first, coordinated with that session through Agent Mail.

## 5. Grants and authorization

| Term | Proposed | Why |
|---|---|---|
| **What merging this plan authorizes** | Creating the Google identity in A2, and building Epics A and B. | Tier 2. Rollback: delete the account and the pool, and remove it from Play Console. |
| **Merges** | 2 | One PR per Epic. |
| **Epic verification** | Owner | CI config and a live credential; no test command can vouch for it alone. |
| **Owner steps during the run** | Console invite and a look at the closed track's tester list (A2). Opting out of Internal if you joined it. | Everything else I run. |
| **Stops** | Any refusal in section 6. | |
| **Flash** | None | |

`epic_chain` is filled with the Epic issue numbers before you mint, as on #962.

```grant-terms
{
  "epic_chain": [],
  "chain": true,
  "verification": { "mode": "owner" },
  "merge": { "budget": 2, "basis": "Two Epics, one PR each. The plan PR merges before this grant exists." },
  "flash": null,
  "reset": null,
  "expires_after_hours": 168
}
```

## 6. Can't-tell branches

| Where | Can't tell what | Does |
|---|---|---|
| Identity | Token unavailable, or wrong repo, environment or ref | **stop** |
| Source | The tag's commit isn't on `main` | **stop** |
| Bundle | The tag's GitHub release has no AAB | **stop** |
| Bundle | No provenance attestation, or one not from `release-signed.yml` at this tag | **stop** |
| Bundle | Certificate does not match the pin, or is the debug key | **stop** |
| Bundle | Version code differs from the tag's `pubspec` | **stop** |
| Numbering | Tracks unreadable | **stop** |
| Numbering | Code not higher than Play's highest, and not already this release | **stop** |
| Notes | Missing, empty, or over 500 characters | **stop** |
| Target | External given a percentage below 100 | **stop**. External goes to its whole tester list. |
| Target | Requested rollout is narrower than what the track already serves | **stop**. Narrowing or halting is done in Console. |
| Target | A different version is mid-rollout on the target track | **stop**. Finish or halt it in Console first. |
| Target | Track already carries this release at the requested rollout or wider | Succeeds and changes nothing. Both states are known. |
| Review | Play will not auto-send for review (for example, after a rejection) | **stop** and show Play's message. It never retries with review skipped. |

## 7. Verification

- **Named command:** `python -m unittest discover -s tools/play`, added to a PR check.
- **Acceptance bar:** A3's track listing and refusal seen live, then B3's first real release.

**Not verified yet, and how each gets settled:**

| Claim | Status | Settled by |
|---|---|---|
| Closed testing's API track name is `alpha`. | Docs only | A3 reads the real names |
| A keyless GitHub token can be exchanged for a Play-scoped token. | Believed, untested | A3 |
| A bundle already on Play can be set on another track without re-uploading. | Believed, untested | B3 |
| `gh attestation verify --source-ref` accepts the right tag and rejects a different one. | Flag confirmed in `gh` help; behavior untested | A3, before B is built |

## 8. Done when

- A release reaches External or production from one word to me and one click from you, with no file handling.
- A release on External reaches production with one more.
- No Google key file exists anywhere, and no Play credential exists on this machine.
- Test builds never touch Play.

## 9. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Where does a release go after signing? | Nowhere until you choose. Then External, or straight to production. From External, on to production. (2026-11-01, revised 2026-11-03) |
| 2 | Do test builds go to Play? | No. They stay sideloads, so no version codes are used on them. (2026-11-03) |

## 10. Alternatives considered but not chosen

- **Test builds on the Internal track:** each one uses a version code. You declined it on 2026-11-03.
- **Internal app sharing for test builds:** uses no version codes, but means a new link per build, 100 people per link, links expire after 60 days, and no automatic updates. Not asked for.
- **Uploading to External automatically on every tag:** every tag would reach testers before you decided. A dispatch keeps it your call.
- **Open testing as External:** anyone with the link could join. Closed testing keeps External to the people you list.
- **A JSON key in a GitHub secret:** a long-lived credential in a public repo's settings. The keyless route needs none.
- **Reading the next version code from Play:** only needed if test builds uploaded. `pubspec` stays the source, and the tool refuses a code Play has already passed.
- **`fastlane` or a third-party upload action:** adds a dependency that handles publishing credentials, for four REST calls.

## 11. Carried-in work

| Item | Goes to |
|---|---|
| Native debug symbols for ANR traces (#931) | Separate follow-up after this Feature. |

When this plan merges, each Epic and Task gets a GitHub issue and a Citadel task, per canon.

## 12. Review

Gemini 2.5 Pro adversarial review, 2026-11-03, after owner approval.

| Finding | Severity | Outcome |
|---|---|---|
| Keyless condition only named repo and environment | High | **Fixed** in A2: repo ID, environment, `v*` tag ref and `workflow_ref` all required. |
| A swapped release asset passes the certificate and version code check | High | **Fixed** with B0's provenance attestation. Gemini's proposed fix, reading the signed run's workflow artifact, doesn't work here: those artifacts expire after 7 days, and External to production can take longer. |
| Closed track rejects a percentage | Medium | Already excluded: External takes `draft` or 100. A1 now spells out the status for each input. |
| Re-runs and concurrent dispatches | Medium | **Fixed:** idempotent tool (A1), one concurrency group (B1), two new section 6 rows. |
| `draft` meaning unclear | Low | **Clarified** in A1: the release sits on the chosen track unserved, and a later dispatch with a percentage or 100 publishes it. |
| Closed track name may not be `alpha` | Low | Already settled by A3 reading the real names. No change. |

Second pass, same day, on the revision:

| Finding | Severity | Outcome |
|---|---|---|
| A `v*` tag pushed onto an unreviewed commit passes every check | High | **Fixed** in B1: the tag's commit must be on `main`, a protected branch that changes only through the promote PR. Gemini's proposed fix, a tag ruleset limiting who creates `v*` tags, would block the agent that cuts releases. |
| A re-run of `release-signed.yml` replaces the AAB with `--clobber` | Medium | **No change.** A re-run needs your approval on `release-signing` again. Once Play holds a version code, it refuses any other bundle with that code, so a later swap can't reach Play. |
| Verify step needs `id-token: read` | Low | **Corrected:** `id-token` has no read level. B1 now lists `attestations: read`, plus `id-token: write` for the keyless token. |
| Adding a release could knock out another version mid-rollout | Medium | **Fixed** in A1 and section 6: never removes another release; stops on a different version mid-rollout. |
| The provenance check is untested | Medium | **Fixed:** moved into A3, so it's proven before Epic B is built. |
