#!/bin/bash
# Brim installer: builds from source and installs the app and the `brim` command.
#
#   curl -fsSL https://raw.githubusercontent.com/abhargava14/brim/main/install.sh | bash
#
# Set BRIM_REPO to install from a fork, BRIM_REF for a branch or tag.
set -euo pipefail

REPO="${BRIM_REPO:-https://github.com/abhargava14/brim.git}"
REF="${BRIM_REF:-main}"
SRC="${BRIM_SRC:-$HOME/.brim/src}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Brim runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || die "Brim needs macOS 13 Ventura or later."
command -v git >/dev/null || die "git is missing. Run: xcode-select --install"
command -v swift >/dev/null || die "Swift is missing. Run: xcode-select --install (or install Xcode)"

if [[ -d "$SRC/.git" ]]; then
    say "Updating $SRC"
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" checkout -q FETCH_HEAD
else
    say "Downloading Brim"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
fi

say "Building (this takes a minute the first time)"
"$SRC/scripts/build-app.sh" --install

cat <<'DONE'

Brim is running in your notch. Connect your AI tools:

  In the app:      click the island → ⚙, or the ✳ menu bar icon → Connections & Settings
  In the terminal: brim add claude
                   brim add codex
                   brim add copilot
                   brim add openrouter
                   brim status

Run `brim help` for everything else.
DONE
