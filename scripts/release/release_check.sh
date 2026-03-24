#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_PATH="${PROJECT_PATH:-Librarian.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Librarian}"
LOG_DIR="${LOG_DIR:-/tmp}"
BUILD_LOG="$LOG_DIR/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_build.log"
TEST_LOG="$LOG_DIR/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_test.log"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/$(basename "$SCHEME_NAME" | tr '[:upper:]' '[:lower:]')_release_check_derived}"
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
BUG_BACKLOG_FILE="${BUG_BACKLOG_FILE:-v1-bug-backlog.md}"

mkdir -p "$CLANG_MODULE_CACHE_PATH"
export CLANG_MODULE_CACHE_PATH

rm -f "$BUILD_LOG" "$TEST_LOG"

echo "[1/6] Resolving package dependencies"
xcodebuild -resolvePackageDependencies -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" > /dev/null

if [[ -f "$ROOT_DIR/Package.swift" ]]; then
  echo "[2/6] Running swift test"
  swift test | tee "$TEST_LOG"
else
  echo "[2/6] Skipping swift test (no Package.swift at repo root)"
fi

echo "[3/6] Running trust-boundary smoke"
"$ROOT_DIR/scripts/release/trust_boundary_smoke.sh"

echo "[4/6] Building app target"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" build > "$BUILD_LOG" 2>&1

echo "[5/6] Running app test pass"
if ! xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA_PATH" test >> "$BUILD_LOG" 2>&1; then
  if rg -n "not currently configured for the test action|There are no test bundles available to test" "$BUILD_LOG" > /dev/null; then
    echo "No configured tests for scheme $SCHEME_NAME; continuing."
  else
    echo "App test pass failed. See: $BUILD_LOG"
    tail -n 80 "$BUILD_LOG"
    exit 1
  fi
fi

echo "[6/6] Validating warning and bug gates"
if rg -n "warning: .*\\.swift" "$BUILD_LOG" > /dev/null; then
  echo "Build produced warnings. See: $BUILD_LOG"
  rg -n "warning: .*\\.swift" "$BUILD_LOG"
  exit 1
fi

if [[ -f "$BUG_BACKLOG_FILE" ]] && rg -n "^- \[ \] `S0`|^- \[ \] `S1`" "$BUG_BACKLOG_FILE" > /dev/null; then
  echo "Open S0/S1 issues remain in $BUG_BACKLOG_FILE"
  rg -n "^- \[ \] `S0`|^- \[ \] `S1`" "$BUG_BACKLOG_FILE"
  exit 1
fi

echo "Release checks passed."
