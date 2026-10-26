# Quick setup (CLI / Terminal)

Prefer the **Mac app** if you don’t want Terminal: download **Brim.dmg** from
[GitHub Releases](https://github.com/abhargava14/brim/releases/latest)
(**no Xcode, no Command Line Tools**). Full picture: [mac-requirements.md](mac-requirements.md).

This page is for **Terminal** users. Prefer the app for **Add Account…** (menu bar ✳ →
Connections & Settings). CLI is best for status and update.

Current release tag: **[v0.5.1](https://github.com/abhargava14/brim/releases/tag/v0.5.1)**.

## 0. Easiest (no Terminal)

1. Open [releases/latest](https://github.com/abhargava14/brim/releases/latest).
2. Download **Brim.dmg**.
3. Drag to Applications → open (right-click → Open once if needed).

## 1. Install from Terminal (builds from source)

These options **compile** Brim. You need Apple’s **Command Line Tools** only
(`xcode-select --install`) — not the full Xcode App Store app.

`install.sh` **does not** download a prebuilt DMG; it clones and builds.

### A. Pinned install script

Download the script from the **release tag** (not floating `main`), then run it. Do **not**
pipe into `bash`.

```bash
# once, if needed:
xcode-select --install

curl -fsSL https://raw.githubusercontent.com/abhargava14/brim/v0.5.1/install.sh -o install-brim.sh
chmod +x install-brim.sh
./install-brim.sh
```

The script’s built-in pin may lag the DMG release; prefer `BRIM_REF=v0.5.1` (or the tag you installed). To be explicit:

```bash
BRIM_REF=v0.5.1 ./install-brim.sh
# or
BRIM_COMMIT=23eaaf1c7c80ae813202b5d0cf85ecb5db78d082 ./install-brim.sh
```

### B. Homebrew

Formula lives at `packaging/homebrew/brim.rb` (HEAD build from `main`):

```bash
brew install --HEAD abhargava14/tap/brim
open "$(brew --prefix)/opt/brim/Brim.app"   # or: ln -sf … /Applications/
```

Prefer A or C if you want a release pin; Homebrew `--HEAD` tracks `main`.

### C. From source

```bash
git clone https://github.com/abhargava14/brim.git
cd brim
git checkout v0.5.1
./scripts/build-app.sh --install
```

Installs `/Applications/Brim.app`, links `~/.local/bin/brim`, and launches the app.

## 2. First run

```bash
open /Applications/Brim.app          # or: brim open
brim status                          # usage for connected tools
brim update --check                  # report only; no install
```

If Gatekeeper blocks: **right-click Brim → Open** once.

Ensure `~/.local/bin` is on your PATH (`which brim` should resolve).

## 3. Add accounts

**Preferred:** menu bar ✳ → **Connections & Settings** → **Add connection** (or **Add Account…**).
Terminal is not required.

**Optional CLI** (same connection store as the app):

```bash
brim add claude
brim add copilot
brim add openrouter
brim list
```

## 4. Update (no Xcode)

```bash
brim update                 # check GitHub Releases and install if newer
brim update --check         # report only
```

Or menu bar ✳ → **Check for Updates…**. Details: [how-to-update-brim.md](how-to-update-brim.md).

## 5. Verify

```bash
brim --version
which brim                  # e.g. ~/.local/bin/brim → …/Brim.app/Contents/Helpers/brim
ls /Applications/Brim.app
```
