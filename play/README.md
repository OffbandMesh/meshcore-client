# Play Console "What's new"

One file per release: `play/<version>.txt`, e.g. `play/1.1.2-rc.4.txt`.

**Hard limit: 500 Unicode characters.** The release gate (`scripts/release-gate.sh`)
fails the build if this file is missing, empty, or over 500 chars — so the limit is caught
here, not as a Console rejection at upload time.

## Style

Plain language for end users. No issue numbers, no internal terms. Not promotional
(Google's Metadata policy forbids "free", "#1", "best", etc. and ALL-CAPS except a brand
name).

**The owner pastes this into Play Console manually.** CI validates the file; it never
uploads. Play distribution is an external, human-triggered action.
