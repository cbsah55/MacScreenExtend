#!/bin/bash
# Builds ScreenExtend.app from the Swift package.
#   scripts/make-app.sh            build into build/ScreenExtend.app
#   scripts/make-app.sh --install  also copy to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ScreenExtend"
BUNDLE_ID="np.com.chaitanyasah.screenextend.host"
VERSION="0.1"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# Sign with a real certificate when there is one: macOS ties Screen Recording and
# Local Network permission to the signature, and an ad-hoc signature changes on
# every build, which would make macOS ask again each time.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || IDENTITY="-"

swift build -c release

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ScreenExtendHost "$APP/Contents/MacOS/$APP_NAME"

# App icon: built from the PNGs in Resources/AppIcon.iconset (sources are in design/).
mkdir -p "$APP/Contents/Resources"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSBonjourServices</key>
	<array><string>_screenextend._tcp</string></array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>ScreenExtend looks for your devices on the local network so it can use them as extra displays.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [ "${1:-}" = "--install" ]; then
    pkill -x ScreenExtendHost 2>/dev/null || true
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed and launched /Applications/$APP_NAME.app"
fi
