#!/bin/zsh
set -euo pipefail

# Reset Librarian to first-run state for UX testing.
# This script clears:
# - Local database + app support
# - Preferences/UserDefaults (including archive bookmark/location)
# - Saved window state (window sizing/pane sizing autosave)
# - Optional archive folders (if requested)
#
# Usage:
#   ./reset_librarian_state.sh --yes
#   ./reset_librarian_state.sh --yes --delete-test-archive
#   ./reset_librarian_state.sh --yes --delete-archive "/path/to/archive"

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
XCODE_PROJECTS_ROOT="$(dirname "$PROJECT_ROOT")"
DEFAULT_TEST_ARCHIVE="$XCODE_PROJECTS_ROOT/Testing/Archive"

DELETE_PATHS=()
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage:
  ./reset_librarian_state.sh [options]

Options:
  --yes                     Skip confirmation prompt
  --delete-test-archive     Also delete default test archive at ../Testing/Archive
  --delete-archive <path>   Also delete a specific archive folder
  --help                    Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --delete-test-archive)
      DELETE_PATHS+=("$DEFAULT_TEST_ARCHIVE")
      shift
      ;;
    --delete-archive)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --delete-archive" >&2
        exit 1
      fi
      DELETE_PATHS+=("$2")
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

APP_DOMAINS=(
  "com.chrislemarquand.Librarian"
  "com.librarian.app"
)

DIRS_TO_REMOVE=(
  "$HOME/Library/Application Support/com.chrislemarquand.Librarian"
  "$HOME/Library/Application Support/com.librarian.app"
  "$HOME/Library/Containers/com.chrislemarquand.Librarian/Data/Library/Application Support/com.chrislemarquand.Librarian"
  "$HOME/Library/Containers/com.chrislemarquand.Librarian/Data/Library/Application Support/com.librarian.app"
  "$HOME/Library/Saved Application State/com.chrislemarquand.Librarian.savedState"
  "$HOME/Library/Saved Application State/com.librarian.app.savedState"
)

PLISTS_TO_REMOVE=(
  "$HOME/Library/Preferences/com.chrislemarquand.Librarian.plist"
  "$HOME/Library/Preferences/com.librarian.app.plist"
  "$HOME/Library/Containers/com.chrislemarquand.Librarian/Data/Library/Preferences/com.chrislemarquand.Librarian.plist"
  "$HOME/Library/Containers/com.chrislemarquand.Librarian/Data/Library/Preferences/com.librarian.app.plist"
)

echo "This will reset Librarian to first-run state."
echo ""
echo "Will remove:"
for p in "${DIRS_TO_REMOVE[@]}"; do
  echo "  - $p"
done
for p in "${PLISTS_TO_REMOVE[@]}"; do
  echo "  - $p"
done
for p in "${DELETE_PATHS[@]}"; do
  echo "  - $p (archive folder)"
done
echo ""

if [[ $ASSUME_YES -ne 1 ]]; then
  printf "Continue? [y/N] "
  read -r REPLY
  if [[ "${REPLY:l}" != "y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

echo "Stopping Librarian if running..."
pkill -x Librarian 2>/dev/null || true

echo "Clearing defaults domains..."
for domain in "${APP_DOMAINS[@]}"; do
  defaults delete "$domain" 2>/dev/null || true
done

echo "Removing app state directories..."
for p in "${DIRS_TO_REMOVE[@]}"; do
  rm -rf "$p"
done

echo "Removing preference plists..."
for p in "${PLISTS_TO_REMOVE[@]}"; do
  rm -f "$p"
done

if [[ ${#DELETE_PATHS[@]} -gt 0 ]]; then
  echo "Removing selected archive folders..."
  for p in "${DELETE_PATHS[@]}"; do
    rm -rf "$p"
  done
fi

echo ""
echo "Reset complete."
echo "Next launch should behave like first run."
