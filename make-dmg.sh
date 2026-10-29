#!/bin/bash
# Builds Attic.app and packages it as build/Attic.dmg — open the .dmg and drag Attic into Applications.
set -euo pipefail
cd "$(dirname "$0")"

bash ./build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Attic.app/Contents/Info.plist)"
DMG="build/Attic-${VERSION}.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

echo "Packaging ${DMG}..."
cp -R build/Attic.app "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"   # the drag-to-install target
rm -f "${DMG}"
hdiutil create -volname "Attic" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null

echo
echo "Done: ${DMG}"
echo "Open it and drag Attic onto the Applications folder."
open -R "${DMG}"
