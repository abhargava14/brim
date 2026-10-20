#!/bin/bash
# Builds an unsigned Brim.dmg containing Brim.app and an Applications symlink.
#   ./scripts/build-dmg.sh  -> build/Brim.dmg (+ build/Brim.dmg.sha256)
#
# Gatekeeper: right-click Brim.app → Open the first time (see README).
# Notarization (when Developer ID credentials exist): see docs/notarization.md
# and scripts/notarize.sh — this script does not sign or notarize.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Brim.app"
DMG="build/Brim.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/brim-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

./scripts/build-app.sh
[[ -d "$APP" ]] || { echo "error: $APP missing after build" >&2; exit 1; }

cp -R "$APP" "$STAGE/Brim.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Brim" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG"

./scripts/checksum-artifact.sh "$DMG" --write

echo "Built $DMG"
echo "Unsigned / not notarized — first open: right-click Brim → Open (Gatekeeper)."
echo "Checksum: $(cat "${DMG}.sha256")"
ls -lh "$DMG"
