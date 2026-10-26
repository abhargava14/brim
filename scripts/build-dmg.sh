#!/bin/bash
# Builds Brim.dmg: Brim.app and an Applications link on a window that explains the first open.
#   ./scripts/build-dmg.sh  -> build/Brim.dmg (+ build/Brim.dmg.sha256)
#
# The window layout comes from dmgbuild (pip install dmgbuild), which writes it without driving
# Finder, so it also works on CI. Without dmgbuild, a plain DMG is built instead.
#
# Gatekeeper: the first open needs Privacy & Security › Open Anyway (see README).
# Notarization (when Developer ID credentials exist): see docs/notarization.md
# and scripts/notarize.sh — this script does not sign or notarize.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Brim.app"
DMG="build/Brim.dmg"

./scripts/build-app.sh
[[ -d "$APP" ]] || { echo "error: $APP missing after build" >&2; exit 1; }
rm -f "$DMG"

DMGBUILD="${DMGBUILD:-dmgbuild}"
if command -v "$DMGBUILD" >/dev/null; then
    "$DMGBUILD" -s packaging/dmg/settings.py -D app="$APP" "Brim" "$DMG"
else
    echo "warning: dmgbuild not found (pip install dmgbuild); building a plain DMG without the guide." >&2
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/brim-dmg.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/Brim.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Brim" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
fi

./scripts/checksum-artifact.sh "$DMG" --write

echo "Built $DMG"
echo "Not notarized — first open: Privacy & Security › Open Anyway (Gatekeeper)."
echo "Checksum: $(cat "${DMG}.sha256")"
ls -lh "$DMG"
