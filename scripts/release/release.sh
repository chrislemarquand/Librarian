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

echo "Release artifact: $DMG_PATH"
