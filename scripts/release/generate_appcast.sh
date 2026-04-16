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

# generate_appcast writes appcast.xml to the current directory.
pushd "$APPCAST_OUTPUT_DIR" >/dev/null
"$SPARKLE_GENERATE_APPCAST" "$ARTIFACT_DIR"
popd >/dev/null

if [[ ! -f "$APPCAST_OUTPUT_DIR/appcast.xml" ]]; then
  echo "generate_appcast completed but appcast.xml was not created in $APPCAST_OUTPUT_DIR" >&2
  exit 1
fi

echo "$APPCAST_OUTPUT_DIR/appcast.xml"
