#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-update-zip>" >&2
  exit 1
fi

ZIP_PATH="$1"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Update ZIP not found: $ZIP_PATH" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPCAST_OUTPUT_DIR="${APPCAST_OUTPUT_DIR:-$ROOT_DIR/build/appcast}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-$ROOT_DIR/SourcePackages/checkouts/Sparkle/bin/generate_appcast}"

if [[ ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
  echo "Sparkle generate_appcast tool not found or not executable: $SPARKLE_GENERATE_APPCAST" >&2
  echo "Set SPARKLE_GENERATE_APPCAST to your Sparkle bin/generate_appcast path." >&2
  exit 1
fi

ARTIFACT_DIR="$(dirname "$ZIP_PATH")"
mkdir -p "$APPCAST_OUTPUT_DIR"

# generate_appcast writes appcast.xml into the archives directory by default.
# Pass the private key via stdin (--ed-key-file -) when SPARKLE_PRIVATE_KEY
# is set, so CI doesn't need a keychain entry.
APPCAST_OUTPUT_FILE="$APPCAST_OUTPUT_DIR/appcast.xml"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "$SPARKLE_PRIVATE_KEY" | \
    "$SPARKLE_GENERATE_APPCAST" --ed-key-file - -o "$APPCAST_OUTPUT_FILE" "$ARTIFACT_DIR" >&2
else
  "$SPARKLE_GENERATE_APPCAST" -o "$APPCAST_OUTPUT_FILE" "$ARTIFACT_DIR" >&2
fi

if [[ ! -f "$APPCAST_OUTPUT_FILE" ]]; then
  echo "generate_appcast completed but appcast.xml was not created at $APPCAST_OUTPUT_FILE" >&2
  exit 1
fi

echo "$APPCAST_OUTPUT_FILE"
