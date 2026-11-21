# GitHub Discussions announcement

One file per release: `announcements/<version>.md`, e.g. `announcements/1.8.0.md`.

## Style

A post for the **Announcements** category of this repo's GitHub Discussions. It's for people
who follow the project on GitHub: what landed, anything to read before updating, every known
issue that ships, and where to get each platform. Plainer than the Discord text, shorter than
the release notes, and it links to the release page for the full notes.

The first line gives the discussion title (`**Title:** ...`), followed by a `---` line. The
post body is everything after that.

**The post goes up after the release is published**, because it links to the release page.
Only the owner posts it, or an agent on the owner's word. CI never posts it, and the release
gate (`.github/scripts/release-gate.sh`) does not check this file.
