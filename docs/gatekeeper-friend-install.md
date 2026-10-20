# If Mac says Brim can’t be opened

Friends downloading **Brim.dmg** often see a dialog like:

> **Brim Not Opened**  
> Apple could not verify “Brim” is free of malware that may harm your Mac or compromise your privacy.

That message is **normal** for the current download until the app is signed with an **Apple
Developer ID** and **notarized**. It does **not** mean Brim is malware.

On **macOS Sonoma / Sequoia**, that dialog often shows only **Done** / **Move to Bin** (no
**Open** button). Right‑click → **Open** usually does nothing useful. Use **Open Anyway** in
System Settings instead.

## What to do (about a minute)

### 1. Put Brim in Applications

Open the DMG and **drag Brim into `/Applications`**. Do not keep launching it only from the DMG
window — Gatekeeper and later opens expect the copy in Applications.

### 2. Try open once (records the block)

Double‑click **Brim** in Applications (or open it once). When the “Apple could not verify…”
dialog appears, click **Done** — **not** **Move to Bin**.

### 3. Open Anyway (current macOS — use this)

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Scroll down to the security messages.
4. Find **“Brim was blocked…”** (or similar) and click **Open Anyway**.
5. If macOS asks again, confirm with your password / Touch ID and **Open Anyway** a second time.

After that, Brim should open like any other app.

### 4. Optional Terminal fallback

Only if **Open Anyway** still fails and you’re okay with Terminal. This clears the quarantine
flag on the app copy; it does **not** turn Gatekeeper off for your Mac.

```bash
xattr -cr /Applications/Brim.app
```

Then open Brim again from Applications.

### Older macOS only — right‑click Open

On older macOS versions, the Gatekeeper dialog may still offer **Open**:

1. In **Finder**, open **Applications**.
2. **Right‑click** (or **Control‑click**) **Brim** → **Open**.
3. In the confirmation dialog, click **Open** again.

On Sonoma/Sequoia this is often ineffective — prefer **Open Anyway** above.

## What not to do

- Do **not** turn off Gatekeeper or run commands that disable system security for all apps.
- Do **not** click **Move to Bin** on the verify dialog if you still want to install Brim.
- Do **not** download Brim from random mirrors — use the official
  [GitHub Releases](https://github.com/abhargava14/brim/releases/latest) **Brim.dmg**.

## Permanent fix (for maintainers)

The lasting fix is Apple **Developer ID** signing + **notarization**, then shipping that DMG on
Releases. Steps and scripts are in [notarization.md](notarization.md)
(`scripts/notarize.sh` and related build scripts in the repo). Until that ships, **Privacy &
Security → Open Anyway** is the expected path for friends on current macOS.

Also see the README section **If Mac says Brim can’t be opened** and
[mac-requirements.md](mac-requirements.md).
