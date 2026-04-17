#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"

APP_PATH="$($ROOT_DIR/scripts/release/archive.sh)"
APP_NAME="$(basename "$APP_PATH" .app)"

ZIP_PATH="$BUILD_DIR/archive/${APP_NAME}.zip"
rm -f "$ZIP_PATH"

ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

$ROOT_DIR/scripts/release/notarize.sh "$ZIP_PATH"

DMG_PATH="$($ROOT_DIR/scripts/release/create_dmg.sh "$APP_PATH")"
$ROOT_DIR/scripts/release/notarize.sh "$DMG_PATH"

if [[ "${GENERATE_APPCAST:-0}" == "1" ]]; then
  $ROOT_DIR/scripts/release/generate_appcast.sh "$ZIP_PATH" >&2
fi

echo "Release artifacts:"
echo "  ZIP: $ZIP_PATH"
echo "  DMG: $DMG_PATH"
