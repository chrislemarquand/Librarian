#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-Librarian.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Librarian}"
LOG_DIR="${LOG_DIR:-/tmp}"
BUILD_LOG="$LOG_DIR/librarian_release_check_build.log"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/librarian_release_check_derived}"

rm -f "$BUILD_LOG"

echo "[1/2] Building app target"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build > "$BUILD_LOG" 2>&1

echo "[2/2] Validating warning gate"
if rg -n "warning: .*\\.swift" "$BUILD_LOG" > /dev/null; then
  echo "Build produced warnings. See: $BUILD_LOG"
  rg -n "warning: .*\\.swift" "$BUILD_LOG"
  exit 1
fi

echo "Release checks passed."
