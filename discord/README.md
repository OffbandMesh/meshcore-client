# Discord announcement

One file per release: `discord/<version>.md`, e.g. `discord/1.1.2-rc.4.md`.

## Style

Casual, paste-ready community announcement. What landed, in plain excited-but-honest
terms, with the download link. Emoji fine. This is the message the owner posts to Discord.

**The owner pastes this into Discord manually.** CI validates the file exists and is
non-empty; it never posts. Posting to a community is an external, human-triggered action.

The release gate (`scripts/release-gate.sh`) fails the build if this file is missing or
empty for the version being tagged.
