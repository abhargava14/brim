#!/bin/bash
# Builds "Brim.app" (with the brim command inside it) from the Swift package.
#   ./scripts/build-app.sh              -> build/Brim.app
#   ./scripts/build-app.sh --install    -> copies to /Applications, links `brim`, launches the app
#   ./scripts/build-app.sh --copy-only  -> copies to /Applications + links CLI; does NOT launch,
#                                         does NOT run oauth/status. For agents / Keychain-safe installs.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Brim"
BUNDLE_ID="com.brim.app"
# Prefer VERSION=… from the environment; else read IslandCore/BrimVersion.swift.
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(sed -n 's/.*static let string = \"\([^\"]*\)\".*/\1/p' Sources/IslandCore/BrimVersion.swift | head -1)"
fi
VERSION="${VERSION:-0.5.2}"
APP="build/$APP_NAME.app"

swift build -c release --product BrimApp
swift build -c release --product brim
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/BrimApp" "$APP/Contents/MacOS/Brim"
cp "$BIN_DIR/brim" "$APP/Contents/Helpers/brim"
# The old command name, kept while people move over.
ln -sf brim "$APP/Contents/Helpers/ai-island"
# Tool logos and other images (SwiftPM resource bundle, found by BrimAssets).
cp -R "$BIN_DIR/Brim_BrimApp.bundle" "$APP/Contents/Resources/"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Brim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Brim shows your week and your next event in the notch.</string>
    <key>NSCalendarsUsageDescription</key><string>Brim shows your week and your next event in the notch.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Brim lists your reminders and lets you tick them off.</string>
    <key>NSRemindersUsageDescription</key><string>Brim lists your reminders and lets you tick them off.</string>
    <key>NSLocationUsageDescription</key><string>Brim uses your city to show the weather. It never stores where you are.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Brim uses your city to show the weather. It never stores where you are.</string>
    <key>NSAppleEventsUsageDescription</key><string>Brim controls Spotify or Music when you press play, pause or skip in the notch.</string>
</dict>
</plist>
PLIST

# Signing decides whether updates keep the user's approvals (Keychain "Always Allow", Calendar,
# Location, Launch at Login). macOS ties those to the app's designated requirement.
#  - SIGN_IDENTITY set (a Developer ID): real signature with the hardened runtime; notarize next.
#  - Otherwise ad-hoc, with a fixed requirement (the bundle ID) instead of the default per-build
#    hash, so a new build is still "Brim" to the Keychain and to privacy settings. The CLI uses the
#    same identifier so it shares the app's Keychain items.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp -i "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/brim"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    REQUIREMENT="designated => identifier \"$BUNDLE_ID\""
    codesign --force --sign - -i "$BUNDLE_ID" -r="$REQUIREMENT" "$APP/Contents/Helpers/brim"
    codesign --force --sign - -i "$BUNDLE_ID" -r="$REQUIREMENT" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"

MODE="${1:-}"
if [[ "$MODE" == "--install" || "$MODE" == "--copy-only" ]]; then
    pkill -x Brim 2>/dev/null || true
    pkill -x AIIsland 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app" "/Applications/AI Island.app"
    cp -R "$APP" /Applications/
    CLI="/Applications/$APP_NAME.app/Contents/Helpers/brim"
    BIN="$HOME/.local/bin"
    mkdir -p "$BIN"
    ln -sf "$CLI" "$BIN/brim"
    ln -sf "$CLI" "$BIN/ai-island"
    # Also link into /usr/local/bin when we can write there.
    if [[ -w /usr/local/bin ]]; then
        ln -sf "$CLI" /usr/local/bin/brim
        ln -sf "$CLI" /usr/local/bin/ai-island
    fi
    echo "Linked $BIN/brim (and the old name, ai-island). Make sure $BIN is on your PATH."
    echo "Installed to /Applications/$APP_NAME.app"
    if [[ "$MODE" == "--install" ]]; then
        open "/Applications/$APP_NAME.app"
    else
        echo "Copy-only: app not launched (no oauth / brim status / Keychain reads)."
    fi
fi
