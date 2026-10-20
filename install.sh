#!/bin/bash
# Brim installer: builds from a pinned git commit/tag and installs the app + `brim` command.
#
# Do **not** pipe floating `main` into bash. Download, verify, then run:
#
#   curl -fsSL "https://raw.githubusercontent.com/abhargava14/brim/${BRIM_REF:-main}/install.sh" -o install-brim.sh
#   # Prefer verifying a published install.sh.sha256 from the GitHub release when available.
#   chmod +x install-brim.sh
#   BRIM_COMMIT=<40-char-sha> ./install-brim.sh
#
# Or use Homebrew (builds from source):
#   brew install --HEAD abhargava14/tap/brim
#
# Overrides: BRIM_REPO, BRIM_REF (tag/branch), BRIM_COMMIT (full SHA, preferred),
#            BRIM_SRC, BRIM_DMG + BRIM_DMG_SHA256 (verify a downloaded DMG).
set -euo pipefail

REPO="${BRIM_REPO:-https://github.com/abhargava14/brim.git}"
SRC="${BRIM_SRC:-$HOME/.brim/src}"

# Source-of-truth pin — bump when cutting a release (tag preferred via BRIM_REF=vX.Y.Z).
# This SHA is the hardened install baseline; override with BRIM_COMMIT for another revision.
PINNED_COMMIT="3b2c724d6326131aaf5ad69e8e5f71ae17e3b9ea"  # v0.2.1; bump on each release; override with BRIM_COMMIT
REF="${BRIM_REF:-}"
COMMIT="${BRIM_COMMIT:-}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Brim runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || die "Brim needs macOS 13 Ventura or later."
command -v git >/dev/null || die "git is missing. Run: xcode-select --install"
command -v swift >/dev/null || die "Swift is missing. Run: xcode-select --install (or install Xcode)"

# Resolve what to check out: explicit COMMIT > REF > PINNED_COMMIT.
if [[ -z "$COMMIT" ]]; then
    if [[ -n "$REF" ]]; then
        if [[ "$REF" == "main" || "$REF" == "master" ]]; then
            printf '\033[33mwarning:\033[0m BRIM_REF=%s is a floating branch.\n' "$REF" >&2
            printf '         Prefer a release tag or BRIM_COMMIT=<sha>.\n' >&2
        fi
    else
        COMMIT="$PINNED_COMMIT"
        if [[ "$COMMIT" == *000000000000000000000000000000* ]]; then
            die "install.sh PINNED_COMMIT is unset. Pass BRIM_COMMIT=<sha> or BRIM_REF=<tag>."
        fi
    fi
fi

if [[ -d "$SRC/.git" ]]; then
    say "Updating $SRC"
    if [[ -n "$COMMIT" ]]; then
        git -C "$SRC" fetch --depth 1 origin "$COMMIT"
        git -C "$SRC" checkout -q FETCH_HEAD
    else
        git -C "$SRC" fetch --depth 1 origin "refs/tags/${REF}:refs/tags/${REF}" 2>/dev/null \
            || git -C "$SRC" fetch --depth 1 origin "$REF"
        git -C "$SRC" checkout -q FETCH_HEAD
    fi
else
    say "Downloading Brim (${COMMIT:-$REF})"
    mkdir -p "$(dirname "$SRC")"
    if [[ -n "$COMMIT" ]]; then
        git clone "$REPO" "$SRC"
        git -C "$SRC" fetch --depth 1 origin "$COMMIT"
        git -C "$SRC" checkout -q "$COMMIT"
    else
        git clone --depth 1 --branch "$REF" "$REPO" "$SRC" \
            || { git clone "$REPO" "$SRC" && git -C "$SRC" checkout -q "$REF"; }
    fi
fi

HEAD="$(git -C "$SRC" rev-parse HEAD)"
say "Checked out $HEAD"

if [[ -n "$COMMIT" ]]; then
    short="${COMMIT:0:7}"
    case "$HEAD" in
        "$COMMIT"|${short}*) ;;
        *) die "Checked out $HEAD but BRIM_COMMIT=$COMMIT was requested." ;;
    esac
fi

if [[ -n "${BRIM_DMG:-}" ]]; then
    [[ -f "$BRIM_DMG" ]] || die "BRIM_DMG not found: $BRIM_DMG"
    [[ -n "${BRIM_DMG_SHA256:-}" ]] || die "Set BRIM_DMG_SHA256 to verify $BRIM_DMG"
    say "Verifying DMG checksum"
    actual="$(shasum -a 256 "$BRIM_DMG" | awk '{print $1}')"
    [[ "$actual" == "$BRIM_DMG_SHA256" ]] || die "DMG checksum mismatch (got $actual)"
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
