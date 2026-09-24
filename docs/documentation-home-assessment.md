# Where end-user documentation should live

Research deliverable for [#478](https://github.com/OffbandMesh/meshcore-client/issues/478), under epic [#477](https://github.com/OffbandMesh/meshcore-client/issues/477), initiative [#476](https://github.com/OffbandMesh/meshcore-client/issues/476).

Author: DustyRiver (session f6f6e512). Date of evidence: 2026-08-01 UTC.

Every factual claim below is tagged `[verified]` with its evidence or `[hypothesis]` where it is untested. Claims about vendor behavior are cited to that vendor's own documentation, not to recall.

---

## 1. Current state

### 1.1 What exists today

| Surface | Contents | Audience | Evidence |
|---|---|---|---|
| `offband.org/docs` (Hugo `content/docs.md`) | Three link cards: firmware docs, app docs, GitHub org. No documentation of its own. Returns 200. | Mixed | `[verified]` read `offband-site/content/docs.md`, 12 lines, three `card` shortcodes; `curl` returns 200 |
| `docs.offband.org` | **Does not exist.** No DNS record at all. | n/a | `[verified]` `nslookup docs.offband.org` returns NXDOMAIN; `curl` fails to connect. Note: `offband-site/CLAUDE.md`, `CLAUDE.local.md` and `KNOWLEDGE-TRANSFER.md` all state this subdomain maps to the `/docs` hub. **That claim is wrong and should be corrected in that repo.** |
| The "App docs" card | Points at `https://github.com/OffbandMesh/meshcore-client`, so a user lands on the repository root | Developers | `[verified]` same file, line 9 |
| `meshcore-client/README.md` | 256 lines mixing end-user sections (Download and Install, Features) with developer sections (Building for Release, Project Structure, Code Style, Dependencies) | Both, unseparated | `[verified]` `wc -l` plus heading scan |
| `meshcore-client/docs/` | 17 markdown files: `BLE_PROTOCOL.md`, `PRIVACY_POLICY.md`, `trace-topology-spec.md`, `windows-distribution-and-versioning.md`, plus `llm-consultations/` (9 files), `plans-archive/` (2), `architecture/` (1) | Developers and internal | `[verified]` `find docs -name "*.md"` |
| `meshcore-firmware/docs/` | About 30 files with a curated `index.md` separating "Offband guides" from "Inherited MeshCore docs" | Technical users | `[verified]` directory listing plus `head -40 index.md` |
| `meshcore-client` in-app help | None. No help, onboarding, guide or tutorial screen exists in `lib/screens/` | n/a | `[verified]` filtered listing of `lib/screens/` returned nothing |

**There is no end-user documentation for the client anywhere.** A user who installs from Google Play and wants to know how to pair a radio has no destination.

### 1.2 The finding that reframes the question

`meshcore-firmware` already contains a complete, working MkDocs Material configuration at `mkdocs.yml`:

```yaml
site_name: Offband Docs
theme:
  name: material
  features: [content.action.edit, content.code.copy, search.highlight, search.suggest]
exclude_docs: |
  handoffs/
  assessments/
  plans/
  superpowers/
  llm-consultations/
  llm-consult-prompts/
```

`[verified]` read `/c/Dev/meshcore-firmware/mkdocs.yml`.

Two things follow:

1. **It is never built or deployed.** No workflow in `meshcore-firmware/.github/workflows/` references mkdocs (`grep -rl mkdocs` over that directory returns nothing), and the repository has `has_pages=false`. `[verified]` grep plus `gh api`. So Offband already owns a configured documentation site that nobody has ever published.
2. **Its `exclude_docs` block already solves the client's biggest structural problem.** The client `docs/` tree is more than half internal artifacts (`llm-consultations/`, `plans-archive/`) that must never ship as public pages. The firmware config already encodes exactly that separation.

This moves the question from "what should we build" toward "should we finish what is already configured". SAFELANE is explicit that reuse beats reinvention, so any recommendation that ignores this needs to justify itself.

### 1.3 An option the epic did not list

`offband-site/docs-internal/` contains `bookstack-known-issue-isolated-node-control-flooding.md`, whose header block is BookStack page metadata (page name, suggested book and chapter, tags `troubleshooting, meshcore, corescope, airtime`, "Content field for API: markdown"). `[verified]` read the file.

So **a BookStack wiki already exists somewhere in this orbit**, and documentation-shaped content has already been authored for it. The CoreScope tag points at OKIMesh rather than Offband.

`[hypothesis: untested]` That instance is OKIMesh's, not Offband's. I have not verified who owns it, who administers it, or whether Offband content would be welcome in it. **This is a question for the owner, not something to assume in either direction.** It is carried below as option G.

---

## 2. The decisive constraint: GitHub Wikis are invisible to search engines at this repository's size

This is the single hardest fact in the assessment, so it is sourced carefully.

GitHub's own documentation states:

> "Search engines will only index wikis with 500 or more stars that you configure to prevent public editing."

`[verified]` [About wikis, GitHub Docs](https://docs.github.com/en/communities/documenting-your-project-with-wikis/about-wikis). Corroborated independently by [community discussion #4992](https://github.com/orgs/community/discussions/4992), which documents that GitHub serves `x-robots-tag: none` on wikis below that threshold, a restriction that has been open for over ten years.

Measured against the actual repository:

| Repository | Stars | Threshold | Indexed |
|---|---|---|---|
| `OffbandMesh/meshcore-client` | **3** | 500 | No |
| `OffbandMesh/meshcore-firmware` | 6 | 500 | No |

`[verified]` `gh api repos/OffbandMesh/meshcore-client --jq .stargazers_count` returned 3; firmware returned 6.

The threshold is 166 times the current star count. Note also that the requirement is **dual**: 500 or more stars *and* public editing disabled. Opening the wiki to community contribution forfeits indexing regardless of stars.

GitHub's documentation itself recommends GitHub Pages when search engine indexing matters.

**Consequence.** A GitHub Wiki would not appear in Google. For end-user documentation this is close to disqualifying, because the dominant path to a support answer is a web search, not navigating a repository. Two further limits compound it: wiki edits cannot be gated by pull request review (`[verified]` neither GitHub wiki page documents any PR flow), and by default only collaborators can edit (`[verified]` [Changing access permissions for wikis](https://docs.github.com/en/communities/documenting-your-project-with-wikis/changing-access-permissions-for-wikis)), so the "anyone can fix a typo" appeal only materialises in the configuration that guarantees zero indexing.

This does not make wikis bad. It makes them wrong for *this* job at *this* repository size.

---

## 3. Candidate assessment

Scored against the eleven criteria from #477. `+` favourable, `~` mixed, `-` unfavourable.

| # | Criterion | A: GitHub Wiki | B: Hugo section on offband.org | C: In-repo markdown only | D: MkDocs Material to docs.offband.org | E: In-app help | G: Existing BookStack |
|---|---|---|---|---|---|---|---|
| 1 | Maintenance for one maintainer | + trivial | ~ hand-rolled templates | + none beyond files | + config already written | - ships with the app | + hosted elsewhere |
| 2 | Contribution path | ~ collaborators only by default | ~ second repo | + normal PR | + normal PR plus edit links | - code change | - account on someone's server |
| 3 | Review and revert | **- no PR gating** | + PR | + PR | + PR | + PR | - editor history only |
| 4 | Discoverability | **- not indexed at 3 stars** | + indexed | ~ GitHub only | + indexed | - invisible to search | ~ depends on instance |
| 5 | Search within docs | ~ wiki search only | - none built | - none | **+ built in, offline client-side** | + native | + built in |
| 6 | Versioning with releases | - none | ~ manual | **+ same commit as the code** | + same commit, mike supports versions | + ships with the binary | - none |
| 7 | Offline access | - no | - no | ~ if repo cloned | ~ no by default | **+ yes, the product's own use case** | - no |
| 8 | Localization (18 locales) | - manual pages | ~ Hugo i18n | ~ directory per locale | ~ i18n plugin available | - ARB churn | - manual |
| 9 | Portability and lock-in | - export is awkward | + markdown | **+ plain markdown** | + plain markdown | ~ | **- someone else's platform** |
| 10 | Screenshots and media | ~ wiki uploads | + `static/` | + repo paths | + repo paths, same PR as the UI change | - app assets, size cost | ~ uploads |
| 11 | Cost | + free | + already paid | + free | + already paid | + free | + free to Offband |

Notes on the two that look better in the abstract than in practice:

- **B (Hugo section)** sounds cheapest because the site is already deployed, but `offband-site/layouts/_default/` contains only `baseof.html` and `single.html`. `[verified]` directory listing. There are no section or list templates, no navigation tree, and no search. Choosing B means hand-building a documentation system inside a marketing site. It also separates documentation from the code that changes it, so a client behavior change and its documentation update land in two repositories and two PRs.
- **C (in-repo only)** is excellent for review, versioning and portability, and is exactly what the firmware does today. Its weakness is the reader: a non-technical user sent to a GitHub file tree has no navigation and no search. C is a strong *source* and a weak *destination*.

---

## 4. Recommendation

**Adopt C and D together: markdown in the client repository as the source of truth, published as a MkDocs Material site.**

Concretely:

1. User documentation lives in `meshcore-client/docs/user/`, plain markdown, versioned with the code, changed in the same pull request as the behavior it documents. Firmware docs stay in `meshcore-firmware/docs/` for the same reason.
2. Each repo keeps an `exclude_docs` list so internal artifacts (`llm-consultations/`, `plans-archive/`, `architecture/`, `llm-consult-prompts/`) never ship as public pages. The firmware config already does this.
3. **One** MkDocs Material build aggregates both sources into a single site. See section 4.1, which revises where that build lives.
4. Deployed to Cloudflare Pages, the mechanism this project already uses for the web client and the marketing site. No new vendor, no new bill.
5. The `/docs` page on `offband.org` stops being three cards to elsewhere and becomes the front door that links into the real thing.

**Why this and not the others.** It scores well on every criterion that has teeth here and it is the only option that is mostly already built. It keeps documentation in the same review path as the code, which is the only mechanism that actually stops documentation rotting for a single maintainer. It gives readers navigation and offline-capable client-side search without hand-writing templates. It produces plain markdown, so if the answer is wrong in a year the content moves anywhere.

**Runner-up: B, a Hugo section on `offband.org`.** It wins if the priority is one single site with one brand and one deploy, and it becomes clearly correct if the documentation stays small enough that navigation and search do not matter. What it costs is building docs infrastructure by hand and splitting documentation from the code.

**What would flip the decision:**

- ~~**If the BookStack instance is available to Offband.**~~ **Resolved by the owner, 2026-08-01: the BookStack is OKIMesh's, not Offband's.** Option G is therefore off the table as a home for Offband's own documentation. Standing up a second, Offband-owned BookStack was considered and rejected on cost: BookStack supports **only MySQL 8.0+ or MariaDB 10.6+**, with no SQLite or PostgreSQL option, plus PHP 8.2+, a PHP-capable webserver, and Composer (`[verified]` [BookStack installation requirements](https://www.bookstackapp.com/docs/admin/installation/)). That is a database, a server and an upgrade treadmill for a project with one maintainer. The recommended option requires no database and no server at all, which is the relevant contrast.
- **If the client repository crosses 500 stars** and community editing is not wanted, option A stops being disqualified. At 3 stars this is not a near-term consideration.
- **If offline documentation is judged essential rather than desirable.** Then E stops being a complement and becomes a requirement, and the recommendation should be sequenced to make in-app help first rather than later. Given the product exists for the moments when connectivity is gone, this deserves the owner's explicit view.

---

## 4.1 Client and firmware: one site, and the build does not live in either code repo

Raised by the owner, 2026-08-01: if the docs build runs in `meshcore-client`, what happens to `meshcore-firmware`?

The original wording of this recommendation had the client repo own `docs.offband.org`. That was wrong on its face. The hostname is org-level and neutral, and the firmware has the stronger claim to it today, since it has roughly 30 documentation files and a configured `mkdocs.yml` while the client has none. Letting either code repo own the shared hostname is an arbitrary land grab that the other repo then has to work around.

**Users do not think in repositories.** Someone asking "how do I set up MQTT on my observer" (firmware) and "how do I read a path trace" (client) is one person, in one sitting, with one radio. Two sites means two search boxes and a guess about which one holds the answer. That is a worse product for no benefit.

**Revised structure:**

| Piece | Where |
|---|---|
| Client docs source | `meshcore-client/docs/user/` |
| Firmware docs source | `meshcore-firmware/docs/` (unchanged, already exists) |
| The build | **`offband-site`**, the neutral repo, which already owns `offband.org/docs` and already has Cloudflare Pages deployment solved |
| Published at | `docs.offband.org/app/...` and `docs.offband.org/firmware/...`, one nav, one search index |

**Why the build belongs in `offband-site`:** it is neutral, so neither code repo grabs the shared hostname; Cloudflare Pages deployment is already working there; the docs entry page (`offband.org/docs`) and the docs site end up in the same repo; and neither code repo takes a build dependency on the other.

**This does not weaken the anti-rot property**, which was the main argument for the recommendation. The *sources* still live beside the code and still change in the same pull request as the behavior they describe. Only the *publish step* is centralized.

**How the build gets the content.** Two approaches, to be settled in the plan phase:

- **Plain:** a CI step does a shallow `git clone` of each code repo's `docs/` into the build tree. No third-party dependency, nothing to break when a plugin goes unmaintained. This is the recommended starting point.
- **Plugin:** [mkdocs-multirepo-plugin](https://github.com/jdoiro3/mkdocs-multirepo-plugin) or [mkdocs-monorepo-plugin](https://github.com/backstage/mkdocs-monorepo-plugin) do this natively with nav integration. `[verified]` both exist and are published. Worth evaluating, but a plugin is a maintenance liability the plain approach does not carry.

**Republish trigger:** a `repository_dispatch` from each code repo when a merge touches `docs/`, so a documentation change goes live without waiting on an unrelated site commit.

**An open sub-question for the build phase, not for now:** whether the build pulls each repo's default branch or its latest release tag. Pulling the branch means the site can describe unreleased behavior. Pulling the tag keeps docs aligned with what users actually have installed. The second is probably right for the client, which ships to Play.

**A useful consequence.** The firmware already has around 30 documentation files and the client has zero. Building the unified site means **it launches with real content on day one**, carrying firmware docs, rather than sitting empty until client documentation is written. The client section then fills in over time against a site that is already live and already indexed.

---

## 5. Proposed table of contents

Sized to what one maintainer can sustain. Everything here is answerable from the existing screens, so nothing needs new features.

**Getting started**
1. Install: Android, Windows, web
2. Connect a radio: BLE, TCP, USB serial
3. First contact and first message

**Everyday use**
4. Contacts and direct messages
5. Channels and communities
6. Reactions, mentions and replies
7. Message delivery: acknowledgements, retries, why a message says failed

**Map and location**
8. Reading the map: node positions and freshness
9. Path trace and how to read a hop path
10. Line of sight
11. Offline tile cache

**Devices and repeaters**
12. Device settings and radio parameters
13. The repeater hub: status, settings, CLI
14. Telemetry and battery

**App**
15. Settings reference
16. Translation and the on-device model
17. Import and export, config profiles

**Help**
18. Troubleshooting
19. FAQ
20. How to report a bug and capture a log

Localization is deliberately excluded from the first pass. The app ships 18 locales, but translating documentation multiplies maintenance by 18 for a single maintainer. Recommendation is English first, then measure demand from actual users before committing.

---

## 6. Migration and URL plan

Little is published, so this is cheap now and gets more expensive with every month it waits.

| Item | Now | Proposed | Risk |
|---|---|---|---|
| `docs.offband.org` | **Nothing. No DNS record.** | New CNAME to a new Cloudflare Pages project fed by this repo's CI | **None.** The hostname is unused, so it is created rather than migrated. Nothing to detach, nothing to break, no redirects. |
| `offband.org/docs` | The three cards | Becomes an entry page linking into `docs.offband.org` | None, internal link change |
| "App docs" card, currently to the repo root | Repository root | The getting-started page | Improvement, no dead link |
| `meshcore-client/README.md` | User and developer content mixed | User sections shortened to a link into the docs, developer content stays | Keep anchors alive; the README is linked from Google Play and releases |
| `meshcore-client/docs/*` internal files | Public in the file tree | Stay where they are, excluded from the built site | Must verify `exclude_docs` actually excludes them before first publish |
| Firmware docs | GitHub tree view | Unchanged for now, pending the one-site-or-two decision | None |

No public documentation URLs exist yet for the client, so **there is nothing to break and no redirects to write**. That is the strongest argument for deciding this now rather than after content accumulates in the wrong place.

---

## 7. What I did not do

- I did not build anything, stand up any site, or change `offband-site`. This task is assessment only.
- I did not verify who owns the BookStack instance. That is a question for the owner.
- I did not test MkDocs against this repository's `docs/` tree. The `exclude_docs` behavior is `[verified]` as configured in firmware but `[hypothesis: untested]` as applied to the client's specific directory layout. That test belongs in the build phase.
- I did not measure how much of the existing README can be moved without breaking inbound links from Google Play and GitHub releases. That belongs in the plan phase.

## 8. Decision requested

The epic closes on a decision plus a working skeleton, not on this document. The owner needs to answer:

1. C plus D as recommended, or the runner-up B, or something else?
2. Is the BookStack instance Offband's to use, or is it OKIMesh's?
3. ~~One documentation site for client and firmware, or two?~~ **Answered in section 4.1: one site, build owned by `offband-site`.** Confirm or push back.
4. Is offline in-app help a requirement or a later nice-to-have?
5. ~~Is it acceptable to move `docs.offband.org` off the marketing site?~~ **Withdrawn.** The subdomain does not exist, so there is nothing to move. Remaining question is only whether `docs.offband.org` is the hostname you want for the docs site.

Plan, build and test children get scoped once these are answered.

---

## 10. Adversarial review findings

> **Model correction.** The first run used `gemini-3.1-pro-preview`. Owner decree of 2026-08-01 (Agent Mail msg 348, point 7) binds all Gemini use to **2.5 only, never 3.x**. That message was unread in my inbox when I ran it. The review was re-run on `gemini-2.5-pro`; **section 10.1 is the binding review**, and it found a significant gap the 3.x run missed. Section 10 below is retained because its findings are real and already actioned.

### 10.0 First run (gemini-3.1-pro-preview, superseded)

Run per standards#145 before opening the PR. Every finding was checked against a primary source before being accepted or rejected. The reviewer endorsed the wiki disqualification and did not overturn the recommendation, but it found real defects, most of which land on the build phase (#491) rather than on this decision.

### Accepted

| # | Finding | Verification | Disposition |
|---|---|---|---|
| 1 | **A central `nav:` block would force a second PR in `offband-site` every time a page is added**, destroying the same-PR benefit for structural changes. | `[verified]` [MkDocs configuration](https://www.mkdocs.org/user-guide/configuration/): "By default `nav` will contain an alphanumerically sorted, nested list of all the Markdown files found within the `docs_dir`". `nav` is optional. | **Real, and avoidable.** The build must **not** use an explicit central nav. Rely on directory-inferred nav, or a per-directory nav file owned by each source repo. Added as a hard constraint on #491. This is the most valuable finding. |
| 2 | **Tag versus branch paradox.** If the build pulls the latest release tag, a post-merge `repository_dispatch` rebuilds the same tag and changes nothing. | Self-evident on inspection. | **Real contradiction in section 4.1.** The two ideas are incompatible as written. Resolved on #491: pick one per source, and if tag-pinned, the dispatch must fire on tag creation, not on merge. |
| 3 | **No PR previews or link validation.** A docs change in a code repo cannot build the site, so broken links and bad paths are only discovered after merge. | Follows from the split. | **Real.** #491 gains a `mkdocs build --strict` check runnable from the source repos, so a docs PR fails before merge rather than after. |
| 4 | **Cross-repo relative links** between the app and firmware sections break when viewed as raw markdown on GitHub and are awkward in the aggregated build. | Follows from the split. | **Real.** Needs a link convention decided at build time. |
| 5 | **Localization URL trap.** Publishing at `/app/` today and adding languages later typically forces `/en/app/`, breaking every inbound link. | Consistent with this document's own argument that URLs are the expensive thing to change. | **Real and self-inconsistent on my part.** The language segment should be decided before launch, not after. Added to #491. |
| 6 | **Custom clone script versus plugin is a possible "not invented here" trap.** A bespoke sync script is also a maintenance liability. | Judgment, not fact. | **Fair.** Section 4.1 pre-committed to the plain approach on thin reasoning. Softened: both are evaluated in the build phase on evidence. |
| 7 | **Read the Docs was not assessed at all.** | `[verified]` [RTD supports MkDocs](https://docs.readthedocs.com/platform/stable/intro/mkdocs.html) and offers version management. | **Real gap.** Assessed now, and still not recommended: it adds a hosting vendor where Cloudflare Pages already works and is already paid for. Recorded so the option is on the record rather than ignored. |

### Rejected or corrected

| # | Finding | Why |
|---|---|---|
| 8 | "Read the Docs natively handles multirepo builds." | **Not verified.** RTD's own MkDocs page says nothing about aggregating multiple repositories. Not propagated as fact. The versioning claim is supported; the multirepo claim is not. |
| 9 | "Bundling markdown as Flutter assets was not assessed." | **Inaccurate.** It is option E in section 3 and is now epic #492, which explicitly notes that keeping docs as in-repo markdown is what makes bundling cheap later. The reviewer's supporting argument, that bundling guarantees the docs version matches the app version exactly, is a good one and has been added to #492. |
| 10 | "A plain clone breaks the firmware's existing `mkdocs.yml`." | **Overstated.** The firmware config is not reused as the aggregate build config; a new config is modelled on it. The firmware's own file stays valid for local firmware-only builds. The underlying point about path mapping and absolute links is real and is folded into finding 4. |

### Net effect

The recommendation stands. What changes is the build design: no central nav, resolve tag versus branch, add a pre-merge docs build check, decide the language URL segment before launch, and choose clone-versus-plugin on evidence rather than in advance.

### 10.1 Binding review (gemini-2.5-pro, 2026-08-01)

Re-run on the mandated model. It confirmed the 3.x findings and added one the 3.x run missed entirely, plus it pushed harder on two decisions.

**New, and a genuine gap: cross-repo clone credentials were never addressed.**

For a CI job in `offband-site` to clone `docs/` out of `meshcore-client` and `meshcore-firmware`, it needs credentials, and the assessment said nothing about them. The options are a deploy key whose public half goes on both source repos and whose private half is a secret in `offband-site` (rotation in three places if compromised), or a machine-user PAT with `repo` scope (a high-privilege token and a real leak liability). The `repository_dispatch` trigger needs a token too.

This matters beyond convenience. **SAFELANE §5 explicitly prohibits reaching for a new PAT before auditing existing inventory**, following the 2026-04-25 PAT-proliferation incident. So the credential decision is governed, not free, and it partly undercuts the "plain clone avoids dependencies" argument, since it trades a plugin dependency for a secrets-management surface. **Added to #491 as a design item that must be settled before the build starts, with the existing credential inventory audited first.**

**Pushed harder, and worth the owner's attention:**

| Finding | Assessment |
|---|---|
| **Deferring offline in-app help is the single most regrettable decision.** The product exists to work when connectivity is gone, and the documentation will live behind the exact connectivity the product replaces. The moment a user most needs help, in the field, is the moment help is unreachable. | **This is a fair challenge to a decision the owner already made** (in-app help filed as #492, backlog, P3). Not overridden here. Surfaced to the owner rather than silently re-prioritised, because gates and priorities are the owner's. |
| **Deferring localization is a trap, not just a URL problem.** Shipping the app in 18 locales sets an expectation the docs then break, and writing 20 English articles first creates a monolithic block of translation debt that is more expensive to clear later than translating as you go. | Stronger than the 3.x version, which only caught the URL structure risk. Recorded. The counter remains that translation multiplies solo-maintainer effort by 18, so this is a real tradeoff rather than an obvious error, and it belongs to the owner. |
| **The same markdown should feed both the site and the app**, so in-app help is a viewer over the same source rather than a separate hand-built effort, which also guarantees the help version matches the installed app version exactly. | Agreed and already the intent. Both #492 and section 4 say the markdown choice is what makes bundling cheap. Made explicit rather than implied. |
| **Same-PR benefit survives for content, not structure.** Navigation, cross-links and any new MkDocs plugin all require a second PR in `offband-site`. | Consistent with finding 1 above. The no-central-nav constraint mitigates the navigation case but not the plugin case. Honest statement: the property holds for the common case and not for structural change. |

**Net.** The recommendation still stands, and no reviewer has argued for a different home. What the binding review changes is that **#491 gains a credentials design item that must be resolved before any build work**, and two owner-level questions are put back on the table: whether offline help really belongs in the backlog, and whether localization should be planned for now rather than later.
