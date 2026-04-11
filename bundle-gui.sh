#!/bin/bash
set -euo pipefail

APP_NAME="PhotoSnail"
EXECUTABLE="photo-snail-gui"
BUILD_DIR=".build/release"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "Building ${EXECUTABLE}..."
swift build -c release --product "${EXECUTABLE}"

echo "Packaging ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PhotoSnail</string>
    <key>CFBundleIdentifier</key>
    <string>com.laurentchouinard.photo-snail-gui</string>
    <key>CFBundleName</key>
    <string>PhotoSnail</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>PhotoSnail reads your Photos library to generate descriptions and tags for each photo using a local AI model.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>PhotoSnail writes AI-generated descriptions and tags back to your Photos library metadata.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PhotoSnail drives Photos.app via AppleScript to write descriptions that sync via iCloud.</string>
</dict>
</plist>
PLIST

echo -n "APPL????" > "${APP_DIR}/Contents/PkgInfo"

echo ""
echo "Done: ${APP_DIR}"
echo "  open '${APP_DIR}'"
echo "  cp -R '${APP_DIR}' /Applications/   # to install"
