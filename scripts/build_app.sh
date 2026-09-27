#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Building Lyra release binary..."
cd "${ROOT_DIR}"
swift build -c release --product LyraApp

BIN_PATH="${ROOT_DIR}/.build/release/LyraApp"
APP_DIR="${ROOT_DIR}/build/Lyra.app"

echo "==> Constructing App Bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/LyraApp"
cp "${ROOT_DIR}/resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

echo "==> Ad-hoc code signing Lyra.app with entitlements..."
codesign --force --deep --sign - --entitlements "${ROOT_DIR}/resources/Lyra.entitlements" "${APP_DIR}"

echo "==> Successfully created ${APP_DIR}"
