#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/Librarian.xcodeproj}"
SCHEME_NAME="${SCHEME_NAME:-Librarian}"
APP_NAME="${APP_NAME:-$(awk -F'=' '/^APP_DISPLAY_NAME[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT_DIR/Config/Base.xcconfig")}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ARCHIVE_PATH="$BUILD_DIR/archive/${APP_NAME}.xcarchive"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Team ID.}"
: "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to your Developer ID Application identity.}"
: "${APP_NAME:?Set APP_NAME or APP_DISPLAY_NAME in Config/Base.xcconfig.}"

mkdir -p "$BUILD_DIR/archive"
ARCHIVE_LOG="$BUILD_DIR/archive/xcodebuild.log"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  archive 2>&1 | tee "$ARCHIVE_LOG" >&2

APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Archive succeeded but no app bundle was found in $ARCHIVE_PATH/Products/Applications" >&2
  exit 1
fi

# Sign bundled Mach-O binaries that xcodebuild may leave unsigned, then
# re-sign the app so notarization sees a fully consistent bundle.
echo "Signing nested Mach-O binaries..." >&2
while IFS= read -r f; do
  if /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -q "Mach-O"; then
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$f" >&2
  fi
done < <(find "$APP_PATH" -type f -not -path "*/MacOS/*")

echo "Re-signing nested XPC services..." >&2
while IFS= read -r xpc; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$xpc" >&2
done < <(find "$APP_PATH" -type d -name "*.xpc" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

echo "Re-signing nested frameworks..." >&2
while IFS= read -r framework; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$framework" >&2
done < <(find "$APP_PATH" -type d -name "*.framework" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

echo "Re-signing app bundle..." >&2
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
  --entitlements "$ROOT_DIR/Config/Librarian.entitlements" "$APP_PATH" >&2

echo "$APP_PATH"
