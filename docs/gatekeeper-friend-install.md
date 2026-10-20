# If Mac says Brim can’t be opened

Friends downloading **Brim.dmg** often see a dialog like:

> **Brim Not Opened**  
> Apple could not verify “Brim” is free of malware that may harm your Mac or compromise your privacy.

That message is **normal** for the current download until the app is signed with an **Apple
Developer ID** and **notarized**. It does **not** mean Brim is malware.

## What to do (about 30 seconds)

Double‑clicking Brim alone usually fails on recent macOS. Use one of these instead.

### Option A — Right‑click Open (recommended)

1. Open **Finder**.
2. Go to **Applications**.
3. **Right‑click** (or **Control‑click**) **Brim**.
4. Choose **Open**.
5. In the confirmation dialog, click **Open** again.

You only need this once for that install. After that, Brim opens like any other app.

### Option B — Privacy & Security

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Scroll until you see a message that Brim was blocked.
4. Click **Open Anyway**, and confirm if asked.

## What not to do

- Do **not** turn off Gatekeeper or run commands that disable system security for all apps.
- Do **not** download Brim from random mirrors — use the official
  [GitHub Releases](https://github.com/abhargava14/brim/releases/latest) **Brim.dmg**.

## Permanent fix (for maintainers)

The lasting fix is Apple **Developer ID** signing + **notarization**, then shipping that DMG on
Releases. Steps and scripts are in [notarization.md](notarization.md)
(`scripts/notarize.sh` and related build scripts in the repo). Until that ships, the right‑click
**Open** workaround above is the expected path for friends.
