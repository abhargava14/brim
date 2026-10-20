# Quick setup (CLI / Terminal)

Short path for Terminal. Prefer the app for **Add Account…** (menu bar ✳ → Connections & Settings). CLI is best for install, status, and update.

Current release: **[v0.3.0](https://github.com/abhargava14/brim/releases/tag/v0.3.0)** (`3f71262`). Needs macOS 13+ and `xcode-select --install` (builds from source).

## 1. Install (pick one)

### A. Pinned install script (recommended)

Download the script from the **release tag** (not floating `main`), then run it. Do **not** pipe into `bash`.

```bash
curl -fsSL https://raw.githubusercontent.com/abhargava14/brim/v0.3.0/install.sh -o install-brim.sh
chmod +x install-brim.sh
./install-brim.sh
```

The script’s built-in pin is v0.3.0 (`3f71262…`). To be explicit:

```bash
BRIM_REF=v0.3.0 ./install-brim.sh
# or
BRIM_COMMIT=3f712624237927d8ee6287e33c6f1eb0efb11e69 ./install-brim.sh
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
git checkout v0.3.0
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

**Preferred:** menu bar ✳ → **Connections & Settings** → **Add connection** (or **Add Account…**). Terminal is not required.

**Optional CLI** (same connection store as the app):

```bash
brim add claude
brim add copilot
brim add openrouter
brim list
```

## 4. Update

```bash
brim update                 # check GitHub Releases and install if newer
brim update --check         # report only
```

Or menu bar ✳ → **Check for Updates…**. Details: [how-to-update-brim.md](how-to-update-brim.md).

## 5. Verify

```bash
brim --version              # expect 0.2.2
which brim                  # e.g. ~/.local/bin/brim → …/Brim.app/Contents/Helpers/brim
ls /Applications/Brim.app
```
