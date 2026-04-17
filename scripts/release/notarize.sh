#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-app-or-dmg-or-zip>" >&2
  exit 1
fi

ARTIFACT="$1"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile name.}"

xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait

# Stapler only works with .app, .pkg, and .dmg — skip for ZIP archives.
if [[ "$ARTIFACT" != *.zip ]]; then
  xcrun stapler staple "$ARTIFACT"
fi
