#!/bin/sh
set -euo pipefail

DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/exiftool/bin"
DEST_FILE="${DEST_DIR}/exiftool"
REQUIRED_VERSION="${EXIFTOOL_REQUIRED_VERSION:-13.50}"

if [ -n "${EXIFTOOL_SOURCE_PATH:-}" ] && [ -x "${EXIFTOOL_SOURCE_PATH}" ]; then
  SRC="${EXIFTOOL_SOURCE_PATH}"
elif [ -x "${SRCROOT}/Vendor/exiftool/bin/exiftool" ]; then
  SRC="${SRCROOT}/Vendor/exiftool/bin/exiftool"
elif [ -x "${SRCROOT}/Vendor/exiftool/exiftool" ]; then
  SRC="${SRCROOT}/Vendor/exiftool/exiftool"
elif [ -x "/opt/homebrew/bin/exiftool" ]; then
  SRC="/opt/homebrew/bin/exiftool"
elif [ -x "/usr/local/bin/exiftool" ]; then
  SRC="/usr/local/bin/exiftool"
else
  echo "error: exiftool not found. Place exiftool in Vendor/exiftool or set EXIFTOOL_SOURCE_PATH."
  exit 1
fi

SRC_REAL="$(perl -MCwd=realpath -e 'print realpath shift' "${SRC}")"
SRC_DIR="$(dirname "${SRC_REAL}")"

LIB_SRC=""
for CANDIDATE in \
  "${SRC_DIR}/lib" \
  "${SRC_DIR}/../lib" \
  "${SRC_DIR}/../libexec/lib" \
  "${SRC_DIR}/../libexec/lib/perl5" \
  "${SRCROOT}/Vendor/exiftool/bin/lib" \
  "${SRCROOT}/Vendor/exiftool/lib"
do
  if [ -f "${CANDIDATE}/Image/ExifTool.pm" ]; then
    LIB_SRC="${CANDIDATE}"
    break
  fi
done

if [ -z "${LIB_SRC}" ]; then
  echo "error: could not locate Image/ExifTool.pm near ${SRC_REAL}."
  exit 1
fi

SRC_VERSION="$(PERL5LIB="${LIB_SRC}" "${SRC_REAL}" -ver 2>/dev/null || true)"
if [ -z "${SRC_VERSION}" ]; then
  echo "error: unable to run exiftool at ${SRC_REAL} with libs at ${LIB_SRC}."
  exit 1
fi

if [ "${SRC_VERSION}" != "${REQUIRED_VERSION}" ]; then
  echo "error: exiftool version ${SRC_VERSION} found, but ${REQUIRED_VERSION} is required."
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp "${SRC_REAL}" "${DEST_FILE}"
chmod 755 "${DEST_FILE}"
rm -rf "${DEST_DIR}/lib"
cp -R "${LIB_SRC}" "${DEST_DIR}/lib"

echo "Bundled exiftool ${SRC_VERSION} from ${SRC_REAL}"
