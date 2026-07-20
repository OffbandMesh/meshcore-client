# GitHub release notes

One file per release: `release-notes/<version>.md`, where `<version>` is the marketing
version from `pubspec.yaml` (the part before `+`), e.g. `release-notes/1.1.2-rc.4.md`.

CI sets the GitHub release body from this file verbatim. It is **published directly** —
the notes are reviewed in the release-cut PR, so there is no draft step. What is in this
file at tag time is what the world sees.

## Style

Narrative prose, not a bulleted changelog. Written for someone deciding whether to install
or update: what's new, what got fixed, anything they should know. Full Markdown is fine.

This is distinct from:
- **`CHANGELOG.md`** — cumulative, terse, issue-referenced, for developers.
- **`play/<version>.txt`** — plain, ≤500 chars, for the store.
- **`discord/<version>.md`** — casual community announcement.

Same underlying changes, four different voices. The release gate
(`scripts/release-gate.sh`) fails the build if this file is missing or empty for the
version being tagged.
