# Notarizing Brim (Developer ID)

Brim's local builds use an **ad-hoc** signature (`codesign --sign -`). Gatekeeper will block
downloaded copies until the user right-clicks → **Open**. Wide distribution needs:

1. Apple Developer Program membership  
2. **Developer ID Application** certificate  
3. Hardened runtime signing  
4. `notarytool` submission + staple  

This repo ships `scripts/notarize.sh` for steps 3–4 once credentials exist. **Nothing here can
complete notarization without those credentials** — that is intentional.

## One-time setup (you)

```bash
# After installing the Developer ID cert in Keychain:
export SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export APPLE_ID='you@example.com'
export APPLE_TEAM_ID='TEAMID'
export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'   # appleid.apple.com → App-Specific Passwords

xcrun notarytool store-credentials brim-notary \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
```

## Release flow

```bash
VERSION=0.2.0 ./scripts/build-app.sh
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --timestamp build/Brim.app
codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp build/Brim.app/Contents/Helpers/brim
./scripts/build-dmg.sh          # ensure the app inside is already Developer ID–signed
NOTARY_PROFILE=brim-notary ./scripts/notarize.sh build/Brim.dmg
./scripts/checksum-artifact.sh build/Brim.dmg --write
```

Publish `Brim.dmg` and `Brim.dmg.sha256` on the GitHub release. Point `install.sh`'s default
`BRIM_REF` at that tag.

## Until then

- Prefer **Homebrew from source** (`brew install --HEAD …`) or a **git clone at a tag/commit**  
- Document Gatekeeper right-click Open (README)  
- Do not claim the DMG is notarized  
