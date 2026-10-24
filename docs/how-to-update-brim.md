# How to update Brim

Quit alone does **not** update — reopening the same `/Applications/Brim.app` never fetches a new build.

**No Xcode required** for normal updates.

1. **Menu bar** ✳ → **Check for Updates…** — Download & Install if a newer GitHub Release exists.
2. Or run **`brim update`** in Terminal (same release channel; `brim update --check` only reports).
3. Or download a newer **Brim.dmg** from [Releases](https://github.com/abhargava14/brim/releases/latest).
4. Or **rebuild** (needs Command Line Tools): Homebrew / pinned `install.sh` / `./scripts/build-app.sh --install`.

Current release: **[v0.5.0](https://github.com/abhargava14/brim/releases/tag/v0.5.0)**.

Requirements table: [mac-requirements.md](mac-requirements.md) · CLI install: [quick-setup-cli.md](quick-setup-cli.md).
