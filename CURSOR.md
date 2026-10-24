# Building Brim with Cursor

> **For you (the human):** unzip `ai-island.zip`, open the unzipped folder in Cursor, then
> paste this into Cursor's Agent chat:
>
> *"Read CURSOR.md and follow it. Start with Phase 1 and stop after each phase to show me the
> result."*
>
> Everything below the line is written for the Cursor agent.

---

## 1. What you're working on

**Brim** is a free, open-source macOS app that sits around the MacBook notch (like the
iPhone's Dynamic Island). Since 0.4 it is a general notch app: the open island has fifteen tabs
(Home, AI, Analytics, Notes, Calendar, Timers, Stats, Screen Time, Weather, Links, Sounds,
Scratchpad, Clipboard, Files, Units) and the closed notch rotates between
now playing, a running timer and AI limits. AI usage is still the core: tokens and plan-limit
percentages per account. Users connect **any number** of tools (Claude Code, Codex,
GitHub Copilot, Cursor, Windsurf, OpenRouter, any log folder, any JSON usage URL), including
several accounts of one tool. There are two ways to connect: the app's Settings window and the
`brim` command-line tool. Both edit the same file.

The code already exists and is complete, but **it has never been compiled**. It was written
without access to a Mac or a Swift toolchain. Your first job is to make it build, pass its
tests and run. Then polish.

## 2. Ground rules (don't change these)

1. **No money, anywhere.** No prices, cost estimates, dollar signs, paid tiers, license keys or
   paywalls. Show tokens and plan percentages only. This was a deliberate product decision.
2. **No limit on connections.** Users can add as many as they like.
3. **Privacy.** No telemetry, analytics or accounts. Never read, store or log prompt, reply or
   code content from the logs, only usage metadata. Tokens go in the Keychain, never in files.
   Account-based tools may only talk to their own service. Tabs ask for a macOS permission only
   when used, and every request first checks the usage text exists (`canAsk`), because asking
   without it terminates the app. Clipboard history stays in memory and skips concealed types.
   Network hosts beyond the AI services: Open-Meteo (weather), DataFast / Google (only for sites
   the user adds), Spotify artwork.
4. **Never guess plan limits.** Percentages must come from the tool or its service.
5. **Keep `IslandCore` Foundation-only** (no AppKit, SwiftUI, Security, SQLite or CryptoKit), so
   its tests run anywhere. macOS readers (EventKit, CoreLocation, IOKit, AppleScript, ImageIO)
   go in `IslandSystem`.
6. **Targets and versions:** macOS 13+, `swift-tools-version:5.9` (Swift 5 language mode). Don't
   switch the package to Swift 6 language mode. Don't add third-party dependencies.
7. **Minimal fixes.** When something doesn't compile, fix it the smallest way that keeps the
   intent. Don't rewrite files or restructure the architecture to make an error go away.
8. Match the existing code style: short doc comments, plain names, no heavy abstraction.
9. **No Keychain / Mac login password dialogs during agent work.** Never run interactive OAuth,
   `brim status`, or Keychain unlock demos. Install with
   `./scripts/build-app.sh --copy-only` (copy `.app` + CLI links only — do **not** `open` the app).
   Background refresh must soft-fail when Keychain is locked (`kSecUseAuthenticationUIFail`).

## 3. Prerequisites (check, don't assume)

Run and report the output:

```bash
sw_vers -productVersion        # needs 13.0 or later
xcode-select -p                # needs Xcode or Command Line Tools
swift --version                # needs Swift 5.9 or later (Xcode 15+)
xcodebuild -version 2>/dev/null || echo "no full Xcode (tests need Xcode)"
```

- No toolchain: ask the user to run `xcode-select --install`, or install Xcode from the App Store.
- `swift test` needs **full Xcode** (XCTest isn't in the Command Line Tools). If only the CLT is
  installed, build without tests and tell the user.

## 4. Project map

Visual check without Keychain or permissions: `BRIM_SNAPSHOT_DIR=/tmp/shots swift run BrimApp`
renders every tab and Settings page (dark and light) with fixture data, then quits.

```
Package.swift                     4 targets + tests
Sources/IslandCore/               Foundation-only logic (unit tested)
  Models.swift                    ToolKind, LogFormat, TokenCounts, PlanWindow, ToolSnapshot, UsageSnapshot
  Connection.swift                Connection (one user connection), LogSource, DefaultLogLocations
  ConnectionStore.swift           ~/Library/Application Support/Brim/connections.json (shared by app + CLI)
  ClaudeLogParser.swift           Claude Code transcript lines + status-line plan windows
  CodexLogParser.swift            Codex rollout lines + rate limits
  AccountUsage.swift              response parsers: Copilot, Cursor, Windsurf, OpenRouter/custom URL
  UsageEngine.swift               incremental log scanning per connection, de-dup, daily totals
  Plans.swift                     plan tiers per tool, billing type
  ClaudeStatusLineSetup.swift     connects/disconnects Claude Code's status line bridge
  Formatting.swift, JSONHelpers.swift
Sources/IslandServices/           macOS services shared by app + CLI
  Connectors.swift                AccountFetcher (network), GitHubCLI, VSCodeState (SQLite), Keychain
Sources/BrimApp/                 the app (AppKit + SwiftUI)
  BrimApp.swift               entry point, AppDelegate, menu bar item
  AppSettings.swift               preferences + the connections list (backed by ConnectionStore)
  UsageModel.swift                runs connections, merges data, raises island "moments"
  IslandController.swift          notch-aware floating NSPanel, hover tracking
  IslandView.swift                compact / moment / expanded views, animations
  SettingsView.swift              connections list, add/remove, plans, tokens, CLI install
  Island/                         tabbed shell (IslandShell), design kit (IslandKit), closed notch,
                                  Settings hooks, ⌥Space hot key
  Tabs/                           one view per tab
  Services/                       app-side stores: notes, links, timers, stats, sounds, clipboard,
                                  converter, launcher, analytics
  Settings/BrimSettingsView.swift the Settings window (General, Tabs, Closed notch, Connections,
                                  Permissions, About)
  Snapshot.swift                  BRIM_SNAPSHOT_DIR=… renders every screen to PNG with fixtures
Sources/IslandSystem/             system stats, calendar, now playing, weather, screen time, images
Sources/BrimCLI/main.swift    the `brim` command
Tests/IslandCoreTests/            XCTest suite for IslandCore
scripts/build-app.sh              builds "Brim.app" with the CLI inside (Contents/Helpers)
install.sh                        one-line installer (clone + build + install)
packaging/homebrew/brim.rb   Homebrew formula (from source)
```

**Data flow:** `AppSettings.connections` → `UsageModel.refresh()` → log connections are scanned
by `UsageEngine` on a background queue (every 5–60 s) and account connections are fetched by
`AccountFetcher` (every 5 min) → `UsageModel.publish()` merges both into a `UsageSnapshot`,
detects moments (`IslandEvent`) → SwiftUI views render it.

## 5. Phase 1: make the core build and pass tests

```bash
swift build --target IslandCore
swift test            # full Xcode only
```

Fix errors in `Sources/IslandCore` and `Tests/` only. Likely problem areas:

- `JSONHelpers.swift`: `NSNumber` casting and `ISO8601DateFormatter` options.
- `UsageEngine.swift`: tuple labels in `configure(_:)` and `jsonlFiles(under:)`, closures in
  `snapshot()`.
- `AccountUsage.swift`: tuple-destructuring `for (key, label) in [...]` loops, optional chains.
- Tests: the expected values were worked out by hand. If a test fails, first decide whether the
  **code** or the **expectation** is wrong, and say which in your summary. Don't weaken
  assertions just to make them pass.

**Done when:** `swift test` passes (or the core builds, if there's no Xcode).

## 6. Phase 2: build the services, CLI and app

```bash
swift build --product brim
swift build --product BrimApp
```

Likely problem areas:

- **Concurrency diagnostics.** Swift 5 mode should give warnings, not errors. If you get errors
  about main-actor isolation in Combine `sink` closures, `Timer` blocks, `NSEvent` monitors or
  `onPreferenceChange`, wrap the body in `Task { @MainActor in … }`, which is the pattern
  already used elsewhere. Don't remove `@MainActor` from classes.
- **CLI (`main.swift`).** Top-level code is deliberately synchronous: async work runs through
  `runBlocking`. Don't add top-level `await` (it changes how globals are isolated).
- **SQLite in `Connectors.swift`.** `import SQLite3` plus the `sqlite3` linker setting in
  `Package.swift`. `SQLITE_TRANSIENT` is defined there as `unsafeBitCast(-1, …)`.
- **SwiftUI availability (macOS 13).** `.contentTransition(.numericText())` is wrapped in
  `if #available(macOS 14, *)`. `onChange(of:) { newValue in }` is the macOS 13 form, so
  deprecation warnings on 14+ are fine. If an SF Symbol name doesn't exist on macOS 13
  (`party.popper.fill`, `gauge.with.dots.needle.67percent`), swap it for a close one.
- **Memberwise inits in views** that have `@State private var` with defaults: if one turns
  private, add an explicit `init`.
- **Result builders.** No `typealias` or other declarations inside `@ViewBuilder` bodies.

**Done when:** both products build with no errors. List any warnings you left and why.

## 7. Phase 3: run it and check behaviour

```bash
swift run brim help
swift run brim list          # creates connections.json with Claude Code + Codex
swift run brim status
swift run BrimApp                # the app (Ctrl-C to quit)
```

Then go through this checklist and report what passes. Fix what doesn't.

**Island**
- [ ] A black island hangs from the top centre; on a notch Mac it wraps the notch with a wing on
      each side. No text sits under the notch.
- [ ] Clicking the menu bar left and right of the island still works (the panel ignores the
      mouse outside the visible island).
- [ ] Hovering expands it to 440 pt with one card per connection; moving away collapses it.
- [ ] With 3+ connections, the compact wings take turns every 4 s with a slide, and page dots show.
- [ ] Claude's icon turns while Claude Code is working (usage in the last 2 minutes).
- [ ] It hides in full-screen apps and never steals keyboard focus.

**Settings (✳ menu bar icon → Connections & Settings)**
- [ ] Add connection → every tool is listed; adding one opens its row.
- [ ] The switch connects and disconnects; Disconnect all / Connect all work.
- [ ] Two Claude connections with different folders show separate totals.
- [ ] Renaming a connection or changing its plan updates the island.
- [ ] Changes made with `brim` in a terminal show up within one refresh, and the reverse.
- [ ] Remove deletes the connection and its Keychain token.

**Moments**
- [ ] Connecting a tool shows "<name> connected" with confetti and a green outline, then returns
      to normal.
- [ ] Turning on Reduce Motion (System Settings → Accessibility) replaces motion with fades.

**Data correctness (Claude Code)**
- [ ] Today's tokens match a manual count: for every `type: "assistant"` line from today in
      `~/.claude/projects/**/*.jsonl`, de-duplicated by `message.id` + `requestId`, add up
      `input_tokens + output_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
      Write a throwaway script to check, and don't commit it.

## 8. Phase 4: check the account connectors

These hit real services. Test only the ones the user actually has, and **ask before using their
accounts**. Copilot, Cursor and Windsurf use private, undocumented endpoints (marked
"experimental" in the UI); the response shapes in `AccountUsage.swift` are best guesses.

| Connector | How it authenticates | Endpoint |
|---|---|---|
| Copilot | `gh auth token` (or a saved token) | `GET https://api.github.com/copilot_internal/user` |
| Cursor | `cursorAuth/accessToken` in Cursor's `state.vscdb` | `GET https://cursor.com/api/usage-summary`, falling back to `/api/usage?user=` |
| Windsurf | `windsurfAuthStatus.apiKey` in Windsurf's `state.vscdb` | `POST https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus` |
| OpenRouter | saved API key | `GET https://openrouter.ai/api/v1/key` (documented) |

For each one the user has:
1. `swift run brim add <tool>`, then `swift run brim status --json`.
2. If parsing fails, capture the real response, **redact** tokens, emails and IDs, and change
   the parser in `AccountUsage.swift` to match it.
3. Add a test that uses the redacted response as its fixture.
4. Never log or print tokens. Never commit real responses that contain personal data.

## 9. Phase 5: package it

```bash
./scripts/build-app.sh              # build/Brim.app with Contents/Helpers/brim
./scripts/build-app.sh --copy-only  # agents: copy to /Applications + link CLI; do not launch
./scripts/build-app.sh --install    # copies to /Applications, links brim, launches it
```

- [ ] The app launches from /Applications, with no Dock icon (LSUIElement).
- [ ] Settings → Terminal → Install links `brim`, and `brim status` works in a new
      terminal.
- [ ] Settings → General → Launch at login works (it needs the app in /Applications).
- [x] Once the user has a GitHub repo, replace `OWNER/brim` in `install.sh`,
      `packaging/homebrew/brim.rb` and `README.md` (now `abhargava14/brim`).
- [ ] CI (`.github/workflows/ci.yml`) passes on GitHub's macOS runner.

## 10. Phase 6 (optional): next features

Only after phases 1–5 pass, and only if the user asks:

1. **"Needs you" and "Done" moments for Claude Code.** Use Claude Code hooks (`Notification` and
   `Stop` events). Add `brim hook <event>` to the CLI, which appends one JSON line (event,
   project folder name, time, no content) to `~/Library/Application Support/Brim/events.jsonl`.
   Install the hooks in `~/.claude/settings.json` the way `ClaudeStatusLineSetup` does: back up
   first and keep any existing hooks. The app watches the file and shows the moments
   (amber "needs you" until answered, green "done" for 6 s).
2. **Signed and notarized release builds** (Developer ID), so users don't see Gatekeeper warnings.
3. **Gemini CLI** or other tools, following "Adding a built-in tool" in the README.

## 11. How to report back

After each phase, send:
- what you ran and the result (pass/fail, with error output when something failed)
- every file you changed, with a one-line reason
- anything you weren't sure about or skipped, and why

Keep commits small, one per phase, with messages that say what was fixed.
