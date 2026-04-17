#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-app-or-dmg-or-zip>" >&2
  exit 1
fi

ARTIFACT="$1"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name.}"

SUBMIT_OUTPUT="$(xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$SUBMIT_OUTPUT" >&2

SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | awk '/id:/{print $2; exit}')"

if echo "$SUBMIT_OUTPUT" | grep -q "status: Invalid"; then
  echo "Notarization FAILED for $ARTIFACT (status: Invalid)" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Fetching notarization log for submission $SUBMISSION_ID..." >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

if [[ "$ARTIFACT" != *.zip ]]; then
  xcrun stapler staple "$ARTIFACT"
fi
