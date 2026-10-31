#!/usr/bin/env bash
# Fails unless a built Runner.app holds the native-asset libraries (#1037).
# An iOS build can compile with them missing, and the app then fails only at
# runtime, when it opens storage or loads translation.
set -eu

app="${1:?usage: ios-assert-frameworks.sh <path to Runner.app>}"
frameworks="${app}/Frameworks"

if [ ! -d "${frameworks}" ]; then
  echo "::error::No Frameworks folder at ${frameworks}."
  exit 1
fi

echo "Frameworks in ${app}:"
ls -1 "${frameworks}"

missing=0
for lib in sqlite3 llama; do
  if ! ls -1 "${frameworks}" | grep -qi "${lib}"; then
    echo "::error::No ${lib} framework in ${frameworks}."
    missing=1
  fi
done
exit "${missing}"
