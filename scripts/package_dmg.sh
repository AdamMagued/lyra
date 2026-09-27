#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure app is built
"${SCRIPT_DIR}/build_app.sh"

APP_PATH="${ROOT_DIR}/build/Lyra.app"
STAGING_DIR="${ROOT_DIR}/build/dmg_staging"
DMG_PATH="${ROOT_DIR}/build/Lyra.dmg"

echo "==> Preparing DMG staging area..."
rm -rf "${STAGING_DIR}"
rm -f "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Creating DMG image with hdiutil..."
hdiutil create \
    -volname "Lyra" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

echo "==> DMG successfully created at ${DMG_PATH}"
ls -lh "${DMG_PATH}"
