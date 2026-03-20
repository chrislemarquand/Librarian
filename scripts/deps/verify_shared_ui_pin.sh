#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PACKAGE_SWIFT="${PACKAGE_SWIFT:-Package.swift}"
SHAREDUI_PATH="${SHAREDUI_PATH:-../SharedUI}"

if [[ ! -f "$PACKAGE_SWIFT" ]]; then
  echo "Missing $PACKAGE_SWIFT"
  exit 1
fi

if rg -q 'https://github.com/chrislemarquand/SharedUI.git' "$PACKAGE_SWIFT"; then
  echo "Error: remote SharedUI dependency detected in $PACKAGE_SWIFT"
  echo "Local-only policy is active. Use: .package(path: \"../SharedUI\")"
  exit 1
fi

if ! rg -q '\.package\(path:[[:space:]]*"\.\./SharedUI"\)' "$PACKAGE_SWIFT"; then
  echo "Error: SharedUI local path dependency is missing in $PACKAGE_SWIFT"
  echo "Expected: .package(path: \"../SharedUI\")"
  exit 1
fi

if [[ ! -d "$SHAREDUI_PATH" ]]; then
  echo "Error: SharedUI local path not found: $SHAREDUI_PATH"
  exit 1
fi

if [[ ! -f "$SHAREDUI_PATH/Package.swift" ]]; then
  echo "Error: SharedUI Package.swift missing at $SHAREDUI_PATH/Package.swift"
  exit 1
fi

sharedui_head="$(git -C "$SHAREDUI_PATH" rev-parse --short HEAD 2>/dev/null || true)"
if [[ -n "$sharedui_head" ]]; then
  echo "SharedUI dependency verified: local path ../SharedUI (HEAD $sharedui_head)"
else
  echo "SharedUI dependency verified: local path ../SharedUI"
fi
