#!/usr/bin/env bash
# Decides whether a manual macOS build of HEAD may be attached to the release
# for <tag> (#1247). The zip has to be the tagged app, so only CI and docs may
# differ between the tag and HEAD. Anything else is refused, naming the files.
#
# usage: macos-manual-check.sh <tag>
set -eu

tag="${1:?tag}"

if ! printf '%s\n' "${tag}" | grep -Eqx 'v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?'; then
  echo "::error::'${tag}' is not a release tag (vX.Y.Z or vX.Y.Z-rc.N)."
  exit 1
fi
if ! git rev-parse -q --verify "refs/tags/${tag}^{commit}" > /dev/null; then
  echo "::error::Tag ${tag} does not exist in this checkout."
  exit 1
fi

changed="$(git diff --name-only "refs/tags/${tag}" HEAD -- . ':!.github' ':!docs')"
if [ -n "${changed}" ]; then
  echo "::error::Files outside .github/ and docs/ changed since ${tag}, so this would not build the tagged app:"
  printf '%s\n' "${changed}"
  exit 1
fi
echo "Only CI and docs differ from ${tag}: this builds the tagged app."
