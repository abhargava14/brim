#!/bin/bash
# Notarize and staple a signed Brim.app / Brim.dmg.
#
# **Blocked without credentials:** this script prepares the Apple notarization flow but cannot
# complete it until you have:
#   1. An Apple Developer Program membership
#   2. A Developer ID Application certificate in the keychain
#   3. An app-specific password (or API key) for notarytool
#
# Usage (once credentials exist):
#
#   export APPLE_ID='you@example.com'
#   export APPLE_TEAM_ID='TEAMID'
#   export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'
#   export SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
#   ./scripts/build-dmg.sh          # or build-app.sh
#   ./scripts/notarize.sh build/Brim.dmg
#
# Optional: NOTARY_PROFILE for a stored notarytool keychain profile instead of env vars.
set -euo pipefail

cd "$(dirname "$0")/.."
TARGET="${1:-build/Brim.dmg}"
[[ -e "$TARGET" ]] || { echo "error: missing $TARGET — build first" >&2; exit 1; }

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    cat <<'MSG' >&2
error: SIGN_IDENTITY is not set.

Notarization requires Developer ID signing. Example:
  export SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp build/Brim.app

Until credentials exist, ship the unsigned/ad-hoc build and document Gatekeeper
(right-click → Open). See docs/notarization.md.
MSG
    exit 1
fi

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# Sign app bundle if the target is a DMG that contains it, or the .app itself.
if [[ "$TARGET" == *.app ]]; then
    say "Signing $TARGET"
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --timestamp "$TARGET"
    codesign --verify --verbose=2 "$TARGET"
elif [[ "$TARGET" == *.dmg ]]; then
    say "Rebuilding DMG contents must already be Developer ID–signed before notarization."
    say "Verify nested Brim.app signature, then submit the DMG."
else
    echo "error: pass build/Brim.app or build/Brim.dmg" >&2
    exit 2
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    say "Submitting to Apple notary service (profile $NOTARY_PROFILE)"
    xcrun notarytool submit "$TARGET" --keychain-profile "$NOTARY_PROFILE" --wait
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    say "Submitting to Apple notary service (Apple ID)"
    xcrun notarytool submit "$TARGET" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
else
    cat <<'MSG' >&2
error: set NOTARY_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD.

Store a profile once credentials exist:
  xcrun notarytool store-credentials brim-notary \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
  export NOTARY_PROFILE=brim-notary
MSG
    exit 1
fi

say "Stapling"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
say "Notarized and stapled: $TARGET"
