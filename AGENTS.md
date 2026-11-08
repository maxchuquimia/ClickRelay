# AGENTS.md

Guidance for coding agents working in this repository.

## What this is

ClickRelay is an unsandboxed macOS app (SwiftUI + a little AppKit, Swift 6 strict concurrency, macOS 15+) that permanently holds Screen Recording and Accessibility, and lends screenshots and input to coding agents through a local MCP server, only while the user has unlocked it (Touch ID, or a human-only Authorize button) for a set time and a chosen set of apps. `README.md` describes what it does for users; the invariants below are the rules behaviour changes must keep. Bundle ID `io.mergeable.ClickRelay`, team `D3NCG82LUC`.

## Build & test

```bash
# Build (Debug also installs a signed copy at /Applications/ClickRelay.app)
xcodebuild -project ClickRelay.xcodeproj -scheme ClickRelay -configuration Debug build

# All unit tests (Swift Testing: @Test, #expect)
xcodebuild -project ClickRelay.xcodeproj -scheme ClickRelay test

# One suite or test
xcodebuild -project ClickRelay.xcodeproj -scheme ClickRelay test -only-testing:ClickRelayTests/LeaseControllerTests
```

Don't pipe `xcodebuild` through `sort`/`tail` while it runs: the output is buffered until the end and a run looks hung. Write to a file and grep it.

Smoke-test the bridge without Claude Code (launches the app in the background if needed):

```bash
( printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"clickrelay_status","arguments":{}}}'; sleep 6 ) \
  | /Applications/ClickRelay.app/Contents/MacOS/ClickRelay --mcp
```

## Signing and install (don't break these)

- Signed with Apple Development for the team, never "Sign to Run Locally". macOS ties the two permissions to the designated requirement; ad-hoc signing changes it every build and the user has to re-grant both.
- App Sandbox is off (a sandboxed app can't drive other apps through Accessibility). Hardened Runtime is on with no exceptions. `ClickRelay.entitlements` is deliberately empty; don't add app-group, network or Apple Events entitlements.
- `scripts/install-debug-copy.sh` (Debug only) copies the app to `/Applications/ClickRelay.app` and re-signs it, nested debug dylibs first, because Xcode signs after the last build phase. That path is what `claude mcp add` registers, so it must stay stable.
- Releases: pushing a `v*` tag runs `.github/workflows/release.yml`, which calls `scripts/release.sh` (unsigned Release build, then Developer ID signing, notarization, staple, zip) and publishes a GitHub release with a provenance attestation. Secrets live only in the `release` environment (tag-restricted, approval required). Never add `pull_request_target` or `workflow_run` triggers, repo-level secrets, or unpinned third-party actions. The header of `scripts/release.sh` lists the secrets it reads.
- `ClickRelay/Info.plist` (screen-capture usage string) and the entitlements file are excluded from the synchronized group's membership in the pbxproj; keep it that way or the build gets duplicate Info.plist outputs.

## Architecture

Two processes, one gate. Claude Code launches this same executable with `--mcp` (the bridge); it relays `tools/call` over a Unix socket to the running app, which checks the lease and allowlist before capturing or posting anything. Only the app ever uses Screen Recording or Accessibility.

- `ClickRelayMain.swift`: `@main`. Branches to `MCPBridge.run()` on `--mcp` **before** `ClickRelayApp.main()`, so the bridge never starts AppKit/SwiftUI or any app state.
- `MCP/MCPBridge.swift`: stdio ↔ socket relay. Answers `initialize`, `ping`, `tools/list` itself; relays only `tools/call`; launches the app in the background (`activates = false`) and queues calls for up to 20 s; fails in-flight calls if the app goes away. Handshake carries session ID, `clientInfo`, working directory, `TERM_PROGRAM`, parent PID. The bridge is charged to the agent's terminal's permissions, so it, `MCPLocal` and `MCPTools` must never reference ScreenCaptureKit, `CGEvent`, `AXUIElement` etc. `BridgeIsolationTests` enforces this by scanning those files.
- `MCP/MCPLocal.swift`: socket location (`~/Library/Application Support/ClickRelay/mcp.sock`, dir 0700, socket 0600, connected by relative path because `sun_path` is 104 bytes), framing (newline-delimited JSON, 16 MB cap), client labels, the setup command.
- `MCP/MCPServer.swift`: POSIX socket listener (not `NWListener`, since the accepted fd is needed) with the peer check: `LOCAL_PEERTOKEN` → `SecCodeCopyGuestWithAttributes` → must satisfy this app's own designated requirement. Anything else is closed. Also `ToolResult`/`ToolContent` and the `MCPBackend` protocol (`AppModel`).
- `MCP/MCPTools.swift`: the 20 tool definitions and `initializeResult` (whose instructions tell agents to focus before input, keep going while time's left, ask with `request_access`, hand passwords and the like to the user with `hand_off`, and finish with `notify`), shared by bridge and app; `ToolArguments` reads arguments leniently (strings for numbers, camelCase for snake_case).
- `MCP/ToolRouter.swift`: the lease gate (with the wait for an unlock) and every tool's implementation. `request_access` and `notify` run before the gate. Input tools run through `InputQueue` (one sequence at a time across all sessions) and re-run `InputGuard` before **every** event. After input, if focus moved to a denied app, further input is refused until `focus_window`. `hand_off` checks run here too: `pausedRefusal` (all input, every session, re-checked per event in `ensureLease`) and `checkNotHandedOff` (capture and AX of the hand-off's app).
- `Access/Lease.swift`: `Lease` (in memory only, never on disk), `LeaseController` (per-session leases on `ContinuousClock`, expiry re-checked in `activeLease(for:)` on every call plus a 1 s timer, extend, idle lock, the per-session "asking for access" request and its waiters, each with its own timeout; explicit `request_access` requests stay up after their wait ends, and a grant or Extend answers them). Takes a `LeaseClock` and an `Authenticator` so tests use fakes.
- `Access/Allowlist.swift` (`AccessPolicy`) and `Access/Denylist.swift`: the boundary. The denylist (ClickRelay, System Settings, auth UI, Dock, password managers…) can't be overridden and is re-checked at use, not just at build. The agent's terminal is found from `TERM_PROGRAM` plus the bridge's process ancestry; if unknown, every known terminal is denied. This is always on (there's no setting); `Denylist.reason(for:agentHosts:)` gives the picker's reason. All hard-coded denying bundle IDs live in `Denylist.swift`.
- `MCP/ScriptFiles.swift` (bridge side): reads the script file for `clickrelay_run_script` from the agent's working directory into the call, writes the file `clickrelay_save_script` returns (its last text block), and answers `clickrelay_validate_script` itself (`ScriptCheck`, no app, no lease). The app never touches the agent's files: the bridge runs as the agent's terminal, which already has access to the project, so reading there costs no privacy prompt, while the app reading `~/Documents` etc. would. Listed in `BridgeIsolationTests`, as is `Scripts/Script.swift`, which the bridge uses to validate.
- `Scripts/`: reusable UI scripts. `Script` (JSON format, parsing, `{{param}}` substitution, validated before anything runs), `ElementMatcher` (identifier, then exact text, then partial; ties go to the front window, then enabled, then interactive), `ElementChooser` (`OnDeviceChooser`: Foundation Models guided generation that can only answer one of the shortlisted candidate ids or none, macOS 26 only, behind `#available`; tests use `FakeChooser`/`NoModelChooser`), `ScriptRunner` (the `ToolRouter` extension: holds `InputQueue` for the whole run, every step through the same lease, allowlist and guard code as single calls, each step reported through `onScriptStep` and logged with `script`, `step`, `matchedBy`), `ScriptRecorder` (each session's successful input calls by ref, turned into steps for `save_script`; coordinate calls are counted, not recorded).
- `Access/LockTriggers.swift`: screen lock, screensaver, sleep, user switch (always on, not settings), app quits, and the kill shortcut (Carbon hot key + global monitor). `Access/SystemAuthenticator.swift`: LocalAuthentication and the Authorize-button prompt; also expiry notifications with Extend.
- `Access/HandOff.swift`: `HandOffController`, one open hand-off per session, its waiters (a timed-out wait leaves it open), and answers nobody was waiting for. `Views/HandOffPanel.swift`: the callout beside the ring and `HumanClickButton`/`HumanButton` (real clicks only, no hold) for Done and Can't Do This. The ring itself is drawn by `OverlayController.handOffRings`.
- `Capture/`: `Screenshotter` (ScreenCaptureKit only; window capture via `desktopIndependentWindow`, display capture including only allowed `SCRunningApplication`s, downscaled to max edge, returns scale and origin) and `WindowCatalog` (CGWindowList snapshot, front to back, global top-left points).
- `Input/`: `InputGuard` (the four checks: window exists/allowed/on screen; point inside; topmost window is it or same app, ignoring ClickRelay's overlay and alpha-0 windows; AX element at point is allowed), `InputPoster` (CGEvents from a private source; tracks held buttons/keys for `releaseAll`), `AXTree` (off-main AX walks, element refs per session), `ShortcutPolicy`, `KeyMap`.
- `Audit/AuditLog.swift`: actor; one JSONL file per day in `…/ClickRelay/Logs/` (0600), thumbnails beside it, typed text and set values redacted unless the setting is on, purge at launch.
- `AppModel.swift`: `@MainActor @Observable` root. Owns everything above, the session list (and today's disconnected ones), calls (with a short `detail`: text typed, keys pressed), lock history, agent notices, the alert panel, Dock badge and bounce, the sidebar selection and the unlock card's draft. Successful calls tell the overlay which window was used. **Start here to trace a feature.** Skips starting services under tests (`isRunningTests`), since the test host is the app.
- `Preferences.swift`: every setting, in `UserDefaults`; inject a suite in tests.
- `Views/`: SwiftUI. `MainView` (first-run `SetupChecklist`, then a `NavigationSplitView` of agents), `AgentDetailView` (header, notice, card, calls), `UnlockView` (`UnlockCard`, `AppPicker`, `DurationPicker`, `Countdown`), `ActivityFeed` (`CallList`), `MenuBarView` and `MenuBarIcon` (the shield glyph, drawn in code); `PermissionsView` (`SetupChecklist`, `AgentSetup` snippets for Claude Code, Codex, Cursor, Windsurf, VS Code, Zed, Antigravity); `OverlayPanel.swift` (AppKit, click-through `.screenSaver` panels: gradient borders only on windows the agent used, pulsing and fading, cleared where covered), `AlertPanel.swift` (AppKit panel under the menu bar item for requests and notices) and `AuthorizeButton.swift` (`HumanOnlyButton`: ignores AX presses, keyboard and posted clicks, needs a 1 s hold).
- Countdowns on screen use `Countdown` (a `TimelineView` around just the text, anchored to the end date); don't wrap whole cards in a `TimelineView`.
- Don't put a `TimelineView` in the `MenuBarExtra` label: it loops forever at launch (and hangs the test host). `AppModel.menuBarTime` is set by the badge timer instead.

## Invariants

- Nothing an agent can send creates, extends or widens a lease, and a request never ticks an app. Only the agent card, Extend (card, menu bar, notification), each behind the unlock method, do. `ToolRouterTests.noToolCanExtendOrWidenALease` covers this.
- Every tool except `clickrelay_status`, `clickrelay_request_access`, `clickrelay_notify` and `clickrelay_validate_script` (`ToolName.worksWhileLocked`) needs `leases.activeLease(for: session.id)`; a lease belongs to one bridge session. Those four must never capture, read AX or post input (`validate_script` only checks script text). `notify` may lock its own lease (`release_access`), never extend it.
- Nothing opens menus. Menu items are pressed directly with the menu closed, from scripts or from `clickrelay_press` on a ref from `find_elements` with `in: "menus"` (stored with `windowID` `ElementStore.menuBar`); a script step that would only open a menu (a menu bar item, or a menu item with a submenu) is skipped, and the same single press is refused. AXPress on a menu bar item leaves the app in menu tracking, which ignores posted keys and holds the mouse (Dock hover stops working). Every menu press and script run closes menus left open in its apps (`AXQuery.closeOpenMenus`) at the start and end, even after the lease ends, like `releaseAll`.
- A script run is only a sequence of single calls: no step can do anything its single call couldn't, and every app it names must be allowed before step 1 runs. The on-device model only picks among elements already read from allowed apps; it never produces text, values or actions.
- Coordinates everywhere are global screen points, top-left origin (CGEvent, AX, ScreenCaptureKit, CGWindowList). Only `NSWindow`/`NSScreen` code (the overlay) converts to bottom-left.
- Refusals are `isError` tool results written for the model: what failed and what to do next. Keep that style when adding checks.
- When a lease ends: `InputPoster.releaseAll()`, element refs dropped, in-flight sequences stop at their next `ensureLease`, and its hand-off ends.
- While any hand-off is open no agent posts input, and its app is never captured or read. Only a real click on Done or Can't Do This ends it early; nothing an agent sends can. A hand-off never pauses or extends the lease clock.
- Concurrency: UI and policy on the main actor; AX tree walks and AX actions in `Task.detached` (a slow app must not freeze Lock now); the audit log is an actor.

## Known limits and open items

- Check-to-event race: a window appearing in the milliseconds between `InputGuard` and the posted event could take a click. Accepted.
- The Authorize button's synthetic-click check (`eventSourceUnixProcessID == 0`, HID state ID) hasn't been confirmed on real hardware; Settings says so.
- `InputDelivery.builtInGlobal` (apps needing Global keyboard delivery) starts empty; add apps to it as testing finds them.
- `_AXUIElementGetWindow` is looked up with `dlsym`; frame matching is the fallback.

## User-facing copy

No em dashes, no filler, plain and specific. Refusal text and UI strings should read like a person wrote them.
