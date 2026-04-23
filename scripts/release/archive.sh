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

# Derive MARKETING_VERSION from the git tag (e.g. v0.2 → 0.2) when available.
# CURRENT_PROJECT_VERSION is computed from the version number as MAJOR*10000 + MINOR*100 + PATCH
# (e.g. 0.2 → 200, 1.0 → 10000) so it is always monotonically increasing and does not require
# a full git history (actions/checkout does a shallow clone by default).
GIT_TAG="${GITHUB_REF_NAME:-$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)}"
if [[ "$GIT_TAG" =~ ^v([0-9].*)$ ]]; then
  MARKETING_VERSION="${BASH_REMATCH[1]}"
else
  MARKETING_VERSION="${MARKETING_VERSION:-$(grep -E '^MARKETING_VERSION' "$ROOT_DIR/Config/Base.xcconfig" | awk -F'=' '{gsub(/[[:space:]]/, "", $2); print $2}')}"
fi
if [[ "$MARKETING_VERSION" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
  BUILD_NUMBER=$(( ${BASH_REMATCH[1]} * 10000 + ${BASH_REMATCH[2]} * 100 + ${BASH_REMATCH[4]:-0} ))
else
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "Building version $MARKETING_VERSION (build $BUILD_NUMBER)" >&2

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
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive 2>&1 | tee "$ARCHIVE_LOG" >&2

APP_PATH="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Archive succeeded but no app bundle was found in $ARCHIVE_PATH/Products/Applications" >&2
  exit 1
fi

# Sign bundled Mach-O binaries that xcodebuild may leave unsigned, then
# re-sign the app so notarization sees a fully consistent bundle.
# osxphotos is handled separately: it is a PyInstaller frozen executable whose
# embedded dylibs (including libpython) carry the original build's Team ID.
# Re-signing with --options runtime is required for notarization, but we must
# also pass disable-library-validation so macOS allows loading those dylibs at
# runtime without enforcing Team ID consistency.
echo "Signing nested Mach-O binaries..." >&2
while IFS= read -r f; do
  if /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -q "Mach-O"; then
    if [[ "$(basename "$f")" == "osxphotos" ]]; then
      codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
        --entitlements "$ROOT_DIR/Config/osxphotos.entitlements" "$f" >&2
    else
      codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$f" >&2
    fi
  fi
done < <(find "$APP_PATH" -type f -not -path "*/MacOS/*")

echo "Re-signing nested XPC services..." >&2
while IFS= read -r xpc; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$xpc" >&2
done < <(find "$APP_PATH" -type d -name "*.xpc" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

echo "Re-signing nested app bundles..." >&2
while IFS= read -r nested_app; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$nested_app" >&2
done < <(find "$APP_PATH" -type d -name "*.app" ! -path "$APP_PATH" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

echo "Re-signing nested frameworks..." >&2
while IFS= read -r framework; do
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime "$framework" >&2
done < <(find "$APP_PATH" -type d -name "*.framework" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

echo "Re-signing app bundle..." >&2
codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp --options runtime \
  --entitlements "$ROOT_DIR/Config/Librarian.entitlements" "$APP_PATH" >&2

echo "$APP_PATH"
