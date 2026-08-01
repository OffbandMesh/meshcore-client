# Where end-user documentation should live

Research deliverable for [#478](https://github.com/OffbandMesh/meshcore-client/issues/478), under epic [#477](https://github.com/OffbandMesh/meshcore-client/issues/477), initiative [#476](https://github.com/OffbandMesh/meshcore-client/issues/476).

Author: DustyRiver (session f6f6e512). Date of evidence: 2026-08-01 UTC.

Every factual claim below is tagged `[verified]` with its evidence or `[hypothesis]` where it is untested. Claims about vendor behavior are cited to that vendor's own documentation, not to recall.

---

## 1. Current state

### 1.1 What exists today

| Surface | Contents | Audience | Evidence |
|---|---|---|---|
| `docs.offband.org` (Hugo `content/docs.md`) | Three link cards: firmware docs, app docs, GitHub org. No documentation of its own. | Mixed | `[verified]` read `offband-site/content/docs.md`, 12 lines, three `card` shortcodes |
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

1. User documentation lives in `meshcore-client/docs/user/`, plain markdown, versioned with the code, changed in the same pull request as the behavior it documents.
2. A `mkdocs.yml` at the client root, modelled directly on the firmware's existing file, with an `exclude_docs` block that keeps `llm-consultations/`, `plans-archive/`, `architecture/` and `llm-consult-prompts/` out of the public site.
3. Built in CI and deployed to Cloudflare Pages, which is the mechanism this project already uses for the web client and the marketing site. No new vendor, no new bill.
4. The `/docs` page on `offband.org` stops being three cards to elsewhere and becomes the front door that links into the real thing.

**Why this and not the others.** It scores well on every criterion that has teeth here and it is the only option that is mostly already built. It keeps documentation in the same review path as the code, which is the only mechanism that actually stops documentation rotting for a single maintainer. It gives readers navigation and offline-capable client-side search without hand-writing templates. It produces plain markdown, so if the answer is wrong in a year the content moves anywhere.

**Runner-up: B, a Hugo section on `offband.org`.** It wins if the priority is one single site with one brand and one deploy, and it becomes clearly correct if the documentation stays small enough that navigation and search do not matter. What it costs is building docs infrastructure by hand and splitting documentation from the code.

**What would flip the decision:**

- **If the BookStack instance is available to Offband and the owner wants it.** Then G plausibly wins on effort alone, since it is a running wiki with search and editing already solved, and OKIMesh users may already be there. The cost is that Offband's documentation would live on infrastructure Offband does not control, and portability becomes a real risk. This needs the owner's answer before it can be scored honestly.
- **If the client repository crosses 500 stars** and community editing is not wanted, option A stops being disqualified. At 3 stars this is not a near-term consideration.
- **If offline documentation is judged essential rather than desirable.** Then E stops being a complement and becomes a requirement, and the recommendation should be sequenced to make in-app help first rather than later. Given the product exists for the moments when connectivity is gone, this deserves the owner's explicit view.

**One question the recommendation deliberately leaves open:** whether client and firmware get one unified documentation site or two. The firmware config is already scoped to firmware only. Unifying is more coherent for a reader and more work; two sites is faster and matches the current repository split. I did not decide this because it is a product judgment, not a technical one.

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
| `docs.offband.org` | Serves the Hugo `/docs` page, three cards | Serves the MkDocs site | **Conflict: the subdomain is already attached to the offband-site Pages project.** It has to be detached and reattached, or the docs site takes a different hostname. This is the one real migration step and it needs deciding before anything is built. |
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
3. One documentation site for client and firmware, or two?
4. Is offline in-app help a requirement or a later nice-to-have?
5. Is it acceptable to move `docs.offband.org` off the marketing site to point at the docs build?

Plan, build and test children get scoped once these are answered.
