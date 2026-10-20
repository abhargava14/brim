#!/bin/bash
# Builds "Brim.app" (with the brim command inside it) from the Swift package.
#   ./scripts/build-app.sh            -> build/Brim.app
#   ./scripts/build-app.sh --install  -> also copies it to /Applications, links `brim` and launches the app
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Brim"
BUNDLE_ID="com.brim.app"
# Prefer VERSION=… from the environment; else read IslandCore/BrimVersion.swift.
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(sed -n 's/.*static let string = \"\([^\"]*\)\".*/\1/p' Sources/IslandCore/BrimVersion.swift | head -1)"
fi
VERSION="${VERSION:-0.3.0}"
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
</dict>
</plist>
PLIST

# Ad-hoc signatures so macOS runs them locally (and Launch at Login works).
codesign --force --sign - "$APP/Contents/Helpers/brim"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
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
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
fi
