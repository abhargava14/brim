# Releasing Brim

Releases are built and published by GitHub Actions (`.github/workflows/release.yml`) when a
version tag is pushed. Nothing is uploaded by hand, and no DMG is committed to the repo: the
README's download button uses
`https://github.com/abhargava14/brim/releases/latest/download/Brim.dmg`, which always serves the
newest release.

## Steps

One pull request with two commits, then a tag:

1. **Version commit:** bump `BrimVersion.string` in `Sources/IslandCore/BrimVersion.swift` (the
   build script reads it) and write the notes in `docs/releases/vX.Y.Z.md` (optional; without it
   GitHub generates notes from the merged pull requests).
2. **Pin commit:** point the installer and docs at the release: `PINNED_COMMIT` in `install.sh`
   set to the version commit's full SHA (merging keeps that commit, so the pin stays valid), and
   the `vX.Y.Z` tag in `README.md`, `docs/how-to-update-brim.md` and `docs/quick-setup-cli.md`.
3. Open the pull request, wait for CI to pass, merge.
4. Tag the merge commit and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "Brim X.Y.Z" <merge-commit>
   git push origin vX.Y.Z
   ```

Pull requests that change the packaging run the same workflow as a dry run (build and check
the DMG, upload it as an artifact, publish nothing), so packaging problems show up before a tag.

The workflow then checks the tag matches `BrimVersion.string`, runs the tests, builds `Brim.dmg`
with its first-open guide (`packaging/dmg/`), checks the app inside keeps the
`identifier "com.brim.app"` signature (so Keychain approvals carry over between updates), records
build provenance, and publishes the release with `Brim.dmg` and `Brim.dmg.sha256`. The in-app
updater and the download button pick it up from there.

## The DMG window

`packaging/dmg/background.tiff` is drawn by `packaging/dmg/make-background.swift`; run
`swift packaging/dmg/make-background.swift` after changing it. Icon positions live in
`packaging/dmg/settings.py` and must match the arrow in the background. To build the DMG locally:

```bash
python3 -m venv .venv-dmg
.venv-dmg/bin/pip install --require-hashes -r packaging/dmg/requirements.txt
DMGBUILD=.venv-dmg/bin/dmgbuild ./scripts/build-dmg.sh
```

## Notarization

Brim isn't notarized yet, so the first open needs Privacy & Security › Open Anyway. Once there's
a Developer ID certificate, see [notarization.md](notarization.md); the workflow is the place to
add it.
