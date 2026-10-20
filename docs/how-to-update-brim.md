# How to update Brim

Quit alone does **not** update — reopening the same `/Applications/Brim.app` never fetches a new build.

1. **Menu bar** ✳ → **Check for Updates…** — Download & Install if a newer GitHub Release exists.
2. Or run **`brim update`** in Terminal (same release channel; `brim update --check` only reports).
3. Or **reinstall**: Homebrew / pinned `install.sh` / `./scripts/build-app.sh --install`.

Current release: **[v0.3.0](https://github.com/abhargava14/brim/releases/tag/v0.3.0)** (`3f71262`).

CLI install path: [quick-setup-cli.md](quick-setup-cli.md).
