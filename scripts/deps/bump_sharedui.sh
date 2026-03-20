#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ $# -ne 0 ]]; then
  echo "Usage: $0"
  echo "Local-only mode: version bumps are not used while SharedUI is a path dependency."
  exit 1
fi

./scripts/deps/verify_shared_ui_pin.sh

echo "Resolving local package dependencies"
swift package resolve

./scripts/deps/verify_shared_ui_pin.sh

echo "Done. SharedUI is synced in local-only mode."
