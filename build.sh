#!/bin/bash
set -euo pipefail

# Directory paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_NAME="PsychAudio.app"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SRC_DIR="${SCRIPT_DIR}/src"
EXECUTABLE_NAME="PsychAudio"
VERSION="1.2.0"

echo "=== Building ${APP_NAME} v${VERSION} for macOS ==="

# 1. Clean previous build artifacts
echo "[1/6] Cleaning dist directory..."
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# 2. Compile Swift sources
echo "[2/6] Compiling Swift sources..."
swiftc \
    -O \
    -framework Cocoa \
    -framework Network \
    -framework ServiceManagement \
    -framework ApplicationServices \
    "${SRC_DIR}/MediaKeyInterceptor.swift" \
    "${SRC_DIR}/WebSocketServer.swift" \
    "${SRC_DIR}/AudioArbitrator.swift" \
    "${SRC_DIR}/AppDelegate.swift" \
    "${SRC_DIR}/main.swift" \
    -o "${MACOS_DIR}/${EXECUTABLE_NAME}"

chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

# 3. Setup bundle metadata & resources
echo "[3/6] Setting up bundle layout, Info.plist, and AppIcon.icns..."
cp "${SRC_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"

if [ -f "${SRC_DIR}/Resources/AppIcon.icns" ]; then
    cp "${SRC_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Write PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# 4. Ad-hoc codesign
echo "[4/6] Ad-hoc codesigning ${APP_NAME}..."
codesign --force --deep -s - "${APP_BUNDLE}"

# 5. Verification
echo "[5/6] Verifying bundle integrity..."
codesign --verify --deep --strict "${APP_BUNDLE}"

# 6. Packaging Release Archive
echo "[6/6] Packaging release archive..."
cd "${DIST_DIR}"
zip -r -y -9 "PsychAudio-v${VERSION}.zip" "${APP_NAME}"

echo ""
echo "=== Build Succeeded! ==="
echo "Application bundle created at:"
echo "  ${APP_BUNDLE}"
echo "Release archive created at:"
echo "  ${DIST_DIR}/PsychAudio-v${VERSION}.zip"
echo ""
echo "You can launch the app directly or copy it to /Applications:"
echo "  cp -R \"${APP_BUNDLE}\" /Applications/"
echo "  open /Applications/${APP_NAME}"
