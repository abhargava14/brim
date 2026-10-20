# Mac requirements (plain language)

Brim runs on **macOS 13 Ventura or later** (Apple silicon or Intel).

## What is what?

| Name | What it is | Do you need it for Brim? |
|---|---|---|
| **Xcode** (App Store) | Apple’s large IDE for building apps — gigabytes | **No** for normal use. Overkill. |
| **Command Line Tools (CLT)** | A small Apple package with `git`, `swift`, and compilers. Install with `xcode-select --install` | Only if you **build Brim from source** |
| **Neither** | Just macOS | Enough for the **DMG** install and in-app updates |

## Path | Needs CLT? | Needs Xcode.app?

| Path | Needs Command Line Tools? | Needs full Xcode.app? |
|---|---|---|
| Download **Brim.dmg** from [GitHub Releases](https://github.com/abhargava14/brim/releases/latest) | No | No |
| Menu bar ✳ → **Check for Updates…** | No | No |
| `brim update` | No | No |
| `install.sh` (compiles on your Mac) | **Yes** | No |
| `./scripts/build-app.sh` | **Yes** | No |
| Homebrew `brew install --HEAD …` | **Yes** (and Homebrew) | No |
| `swift test` / developing Brim | **Yes** (full Xcode optional but fine) | Optional |

## Verified today

- **`install.sh` builds from source.** It checks for `git` and `swift`, clones a pinned commit, and runs `scripts/build-app.sh --install`. It does **not** install by downloading a prebuilt DMG (a `BRIM_DMG` env var only verifies a checksum if you already have a DMG file).
- Prebuilt **Brim.dmg** (and `Brim.dmg.sha256`) ships on [releases/latest](https://github.com/abhargava14/brim/releases/latest) (v0.3.2+).

## If you don’t have Xcode

Use the DMG:

1. [Releases](https://github.com/abhargava14/brim/releases/latest) → download **Brim.dmg**
2. Drag to Applications → open (right-click → Open once if Gatekeeper asks)

That’s the supported path for everyone who isn’t compiling Brim themselves.
