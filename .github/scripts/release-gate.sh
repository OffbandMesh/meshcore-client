#!/usr/bin/env bash
# Release-notes gate. Verifies that every human-authored release text exists and
# is well-formed for the version currently in pubspec.yaml. Run BOTH on the cut
# PR (so it goes red before merge) and as the first job of the tag workflow (a
# cheap backstop before build/sign).
#
# rc.2 and rc.3 shipped with only a pubspec bump and no notes. This makes that
# state impossible: no notes, no release.
#
# Exit 0 = all present and valid. Exit 1 = a hard failure (prints every problem
# before exiting, so one run surfaces all of them, not one at a time).
#
# #342, epic #312.

set -uo pipefail

PLAY_MAX=500

fail=0
note() { printf '  %s\n' "$1"; }
bad()  { printf '::error::%s\n' "$1"; fail=1; }

# --- version from pubspec (strip the +build suffix) -------------------------
VERSION=$(grep -E '^version:' pubspec.yaml | head -1 | sed 's/version:[[:space:]]*//' | sed 's/+.*//' | tr -d '[:space:]')
if [ -z "${VERSION}" ]; then
  bad "Could not read a version from pubspec.yaml."
  exit 1
fi
echo "Release gate for version: ${VERSION}"
echo

# --- 1. CHANGELOG has a section for this version ----------------------------
# Matches a markdown heading containing the version, e.g. "## [1.1.2-rc.4]".
if grep -qE "^#+.*\[?${VERSION//./\\.}\]?" CHANGELOG.md; then
  note "CHANGELOG.md: section for ${VERSION} present"
else
  bad "CHANGELOG.md has no section for ${VERSION}. Add one before releasing."
fi

# --- 2. GitHub release notes exist and are non-empty ------------------------
RN="release-notes/${VERSION}.md"
if [ -s "${RN}" ]; then
  note "release-notes: ${RN} present"
else
  bad "${RN} is missing or empty. This becomes the GitHub release body."
fi

# --- 3. Play 'What's New' exists and is within the length limit -------------
PLAY="play/${VERSION}.txt"
if [ ! -s "${PLAY}" ]; then
  bad "${PLAY} is missing or empty. Required for the Play Console 'What's new'."
else
  # Unicode-aware count (wc -m), matching Google's per-character limit.
  LEN=$(wc -m < "${PLAY}" | tr -d '[:space:]')
  if [ "${LEN}" -gt "${PLAY_MAX}" ]; then
    bad "${PLAY} is ${LEN} chars; Play limit is ${PLAY_MAX}. Trim it."
  else
    note "play: ${PLAY} present (${LEN}/${PLAY_MAX} chars)"
  fi
fi

# --- 4. Discord announcement exists and is non-empty ------------------------
DISCORD="discord/${VERSION}.md"
if [ -s "${DISCORD}" ]; then
  note "discord: ${DISCORD} present"
else
  bad "${DISCORD} is missing or empty. Paste-ready community announcement."
fi

echo
if [ "${fail}" -ne 0 ]; then
  echo "Release gate FAILED for ${VERSION}. Fix the above before tagging."
  exit 1
fi
echo "Release gate passed for ${VERSION}."
