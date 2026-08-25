#!/bin/bash
# Builds DevicePulseMac in Release configuration and packages it into a
# distributable DMG. This produces a LOCALLY signed build ("Sign to Run
# Locally" or whatever Team is configured in Xcode) — fine for running
# on this Mac or Macs signed into the same Apple ID, but macOS Gatekeeper
# will block it on any other Mac until it's signed with a Developer ID
# and notarized. See DISTRIBUTION.md for those steps.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

echo "==> Building Release (unsigned — this folder is iCloud-synced, which"
echo "    stamps Finder/provenance extended attributes that trip up codesign"
echo "    mid-build; we sign manually afterward instead)"
rm -rf build
xcodebuild \
  -project DevicePulse.xcodeproj \
  -scheme DevicePulseMac \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  clean build

APP_PATH="build/Build/Products/Release/Device Pulse.app"
DMG_PATH="build/DevicePulse.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "Build succeeded but app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Stripping iCloud/Finder extended attributes"
xattr -cr "$APP_PATH"

echo "==> Signing locally"
codesign --force --deep --sign - "$APP_PATH"

echo "==> Packaging DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "Device Pulse" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"

echo "==> Done: $DMG_PATH"
