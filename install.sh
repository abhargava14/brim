#!/bin/bash
# AI Island installer: builds from source and installs the app and the `ai-island` command.
#
#   curl -fsSL https://raw.githubusercontent.com/OWNER/ai-island/main/install.sh | bash
#
# Set AI_ISLAND_REPO to install from a fork, AI_ISLAND_REF for a branch or tag.
set -euo pipefail

REPO="${AI_ISLAND_REPO:-https://github.com/OWNER/ai-island.git}"
REF="${AI_ISLAND_REF:-main}"
SRC="${AI_ISLAND_SRC:-$HOME/.ai-island/src}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "AI Island runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || die "AI Island needs macOS 13 Ventura or later."
command -v git >/dev/null || die "git is missing. Run: xcode-select --install"
command -v swift >/dev/null || die "Swift is missing. Run: xcode-select --install (or install Xcode)"

if [[ -d "$SRC/.git" ]]; then
    say "Updating $SRC"
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" checkout -q FETCH_HEAD
else
    say "Downloading AI Island"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
fi

say "Building (this takes a minute the first time)"
"$SRC/scripts/build-app.sh" --install

cat <<'DONE'

AI Island is running in your notch. Connect your AI tools:

  In the app:      click the island → ⚙, or the ✳ menu bar icon → Connections & Settings
  In the terminal: ai-island add claude
                   ai-island add codex
                   ai-island add copilot
                   ai-island add openrouter
                   ai-island status

Run `ai-island help` for everything else.
DONE
