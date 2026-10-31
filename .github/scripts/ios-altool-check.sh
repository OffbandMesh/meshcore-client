#!/usr/bin/env bash
# Decides whether an altool run worked, from its exit code AND its output
# (#1040). altool has exited 0 with an error in its output, so a clean exit alone
# proves nothing, and nothing short of its success line counts as success.
#
# usage: ios-altool-check.sh <validate|upload> <exit code> <output file>
set -eu

mode="${1:?mode}"
code="${2:?exit code}"
output="${3:?output file}"

case "${mode}" in
  validate) success='VALIDATION SUCCEEDED|No errors validating' ;;
  upload) success='UPLOAD SUCCEEDED|No errors uploading' ;;
  *)
    echo "::error::Unknown altool mode '${mode}'."
    exit 1
    ;;
esac

if [ "${code}" != "0" ]; then
  echo "::error::altool ${mode} exited ${code}."
  exit 1
fi
if grep -Eq '\*\*\* Error|ERROR:|FAILED' "${output}"; then
  echo "::error::altool ${mode} exited 0, but its output contains an error."
  exit 1
fi
if ! grep -Eq "${success}" "${output}"; then
  echo "::error::altool ${mode} exited 0, but its output has no success line."
  exit 1
fi
echo "altool ${mode} succeeded."
