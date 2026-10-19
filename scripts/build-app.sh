#!/bin/bash
# Builds "AI Island.app" (with the ai-island command inside it) from the Swift package.
#   ./scripts/build-app.sh            -> build/AI Island.app
#   ./scripts/build-app.sh --install  -> also copies it to /Applications, links `ai-island` and launches the app
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="AI Island"
BUNDLE_ID="com.aiisland.app"
VERSION="${VERSION:-0.2.0}"
APP="build/$APP_NAME.app"

swift build -c release --product AIIsland
swift build -c release --product ai-island
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/AIIsland" "$APP/Contents/MacOS/AIIsland"
cp "$BIN_DIR/ai-island" "$APP/Contents/Helpers/ai-island"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>AIIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures so macOS runs them locally (and Launch at Login works).
codesign --force --sign - "$APP/Contents/Helpers/ai-island"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AIIsland 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    CLI="/Applications/$APP_NAME.app/Contents/Helpers/ai-island"
    if [[ -w /usr/local/bin ]]; then
        ln -sf "$CLI" /usr/local/bin/ai-island && echo "Linked /usr/local/bin/ai-island"
    else
        mkdir -p "$HOME/.local/bin"
        ln -sf "$CLI" "$HOME/.local/bin/ai-island" && echo "Linked ~/.local/bin/ai-island (make sure it's on your PATH)"
    fi
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
fi
