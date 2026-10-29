#!/bin/bash
# Builds "Attic.app" into ./build. Requires Xcode 15+ or the Command Line Tools (macOS 14+).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Attic"
APP="build/${APP_NAME}.app"

echo "Building (release)..."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Attic"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Helpers"
cp "${BIN}" "${APP}/Contents/MacOS/Attic"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
# PDF text helper (reads PDFs in a separate process that can be killed if it hangs)
BIN_DIR="$(dirname "${BIN}")"
if [ -x "${BIN_DIR}/attic-pdftext" ]; then HELPER="${BIN_DIR}/attic-pdftext"; else HELPER="${BIN_DIR}/AtticPDFText"; fi
cp "${HELPER}" "${APP}/Contents/Helpers/attic-pdftext"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Attic</string>
    <key>CFBundleDisplayName</key><string>Attic</string>
    <key>CFBundleIdentifier</key><string>local.attic</string>
    <key>CFBundleExecutable</key><string>Attic</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
touch "${APP}"  # nudge Finder to pick up the icon
codesign --force --sign - "${APP}/Contents/Helpers/attic-pdftext" >/dev/null 2>&1 || true
codesign --force --sign - "${APP}" >/dev/null 2>&1 || echo "Note: codesign failed; the app may still run."

echo "Built: ${APP}"
if ! command -v readpst >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/readpst ] && [ ! -x /usr/local/bin/readpst ]; then
    echo
    echo "One more step: install readpst so the app can read .pst files:"
    echo "    brew install libpst"
fi
echo
echo "Open it with:  open \"${APP}\"   (or drag it into /Applications)"
