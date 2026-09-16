# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

HermesTouchBar is a macOS menu-bar app (LSUIElement, no Dock icon) that projects Hermes Agent runtime state onto a MacBookPro Touch Bar so it is visible across any foreground app. Target hardware is MacBookPro16,1 (2019 16" Intel, Touch Bar); deployment target is macOS 13.0+; arch is x86_64.

The headline trick is that public `NSTouchBar` only renders while the owning app has key focus, so the bar uses private APIs in `TouchBarPrivate/` (dlopen of `DFRFoundation` + dlsym of `DFRElementSetControlStripPresenceForIdentifier`, `DFRSystemModalShowsCloseBoxWhenFrontMost`, plus `NSTouchBar.presentSystemModalTouchBar:systemTrayItemIdentifier:` and `addSystemTrayItem:`) to install a system-modal Touch Bar that floats above the system control strip and survives across app switches. The four runtime symbols are confirmed working on macOS 15.7.9 (see `TouchBarPrivate/TouchBarPrivate.m:14`).

Full design intent, the 9-state mapping, button layout, and risk register live in `docs/DESIGN.md` — read that before changing state semantics or color keys.

## Build & run

There is **no Xcode project file in the working tree**; build is done via a shell script that drives `clang` + `swiftc` directly. `project.yml` is present for XcodeGen but is not what produces the binary.

```bash
./scripts/build.sh          # writes build/HermesTouchBar.app (ad-hoc codesigned)
open build/HermesTouchBar.app
```

`scripts/build.sh`:
1. Copies `Info.plist` + `Assets.xcassets` into the bundle.
2. `clang -fobjc-arc` compiles `HermesTouchBar/TouchBarPrivate/TouchBarPrivate.m` into `build/obj/TouchBarPrivate.o`.
3. `swiftc -target x86_64-apple-macos13.0 -framework AppKit -framework Carbon -lsqlite3` links `TouchBarPrivate.o` + every `*.swift` under `HermesTouchBar/` (excluding the include dir) into `build/HermesTouchBar.app/Contents/MacOS/HermesTouchBar`. The Clang module cache defaults to `/tmp/hermes-touchbar-clang-cache`.
4. `codesign --force --sign -` ad-hoc signs the bundle so it will launch.

To iterate: edit, re-run `./scripts/build.sh`, `open build/HermesTouchBar.app`. To validate the private-API bridge alone, watch `Console.app` for `DFRFoundation` load errors after launch.

## Tests

```bash
./scripts/test.sh
```

Runs standalone smoke checks under `tests/*.swift`. Each smoke file compiles the production sources it needs directly with `swiftc -parse-as-library` and exits non-zero on failure. Not a real XCTest target — the project has no `.xcodeproj` / `Package.swift` yet, so this is a workaround until one of those is decided (see DESIGN.md §11 Tier E).

## High-level architecture

Boot path: `HermesTouchBarApp.main` → `NSApplication` with `.accessory` policy → `AppDelegate.applicationDidFinishLaunching` (`HermesTouchBar/AppDelegate.swift:27`) wires the whole pipeline.

Owned by `AppDelegate`:
- `SkinProvider` (`HermesTouchBar/Skin/SkinProvider.swift`) — loads `~/.hermes/skins/*.yaml` via a tiny hand-rolled YAML parser (no Yams dep) and watches the directory with `DispatchSource.makeFileSystemObjectSource` (NOT `FSEvents`). It also reads `display.skin` out of `~/.hermes/config.yaml` to honor the active skin, and falls back to the built-in `HermesSkin.default` palette for missing keys. Color tokens: see the dict at `HermesTouchBar/Skin/SkinProvider.swift:34`.
- `StatusReader` (`HermesTouchBar/Status/StatusReader.swift`) — every 1.5 s opens `~/.hermes/state.db` read-only via `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)`, reads the most recent session + last 10 messages, parses `gateway.pid` (with `kill(pid, 0)` liveness) and `cron/jobs.json` mtime, and packages the result as a `HermesStatus` snapshot. Home dir is overridable via `HERMES_HOME` env var (`StatusReader.defaultHome()`). Reopens the DB on `state.db` mtime change.
- `StateMachine` (`HermesTouchBar/Status/StateMachine.swift`) — pure function `HermesStatus → HermesState`. No I/O, easy to unit-test. Thresholds (working 5 s, streaming 8 s, ok 12 s, error 30 s, cron 10 s) are tuned for the 1.5 s poll cadence. Priority: `gatewayDown` > `waitingApproval` > recent `error` > working/thinking/streaming/ok based on message timestamps > cron-fired > `ready`/`idle`.
- `TouchBarController` (`HermesTouchBar/TouchBarController.swift`) — assembles the 8-button `NSTouchBar` (`NSCustomTouchBarItem` + `NSButtonTouchBarItem` + an `NSProgressIndicator` for context usage) and calls `PersistentTouchBarAPI.present(...)` to install it as system-modal. Also installs a `TrayBadgeView` (~30×30, tinted with the current state color + state glyph) into the control strip so the user can re-present the bar if macOS hides it.
- `QuickActions` (`HermesTouchBar/QuickActions/QuickActions.swift`) — registers four Carbon hotkeys (`⌃⌥⌘H/N/A/X`, signature `'HERM'`) via `RegisterEventHotKey`. Actions run `osascript` (Terminal launch + `hermes chat`, and `System Events` keystrokes for approve/cancel). Exposes itself as `QuickActions.sharedRef` so Touch Bar button targets can call into it.
- `PersistentTouchBarAPI` (`HermesTouchBar/TouchBarPrivate/PersistentTouchBarAPI.swift`) — thin Swift wrapper around the Obj-C bridge in `TouchBarPrivate.m`. The Obj-C side dlopens `/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation`, resolves the four symbols above, and invokes them on `NSTouchBar` / `NSTouchBarItem` via `methodForSelector:`. The module map `HermesTouchBar/TouchBarPrivate/include/module.modulemap` exposes `TouchBarPrivate.h` to Swift.

Data flow each tick (1.5 s): `Timer` → `StatusReader.snapshot` → `StateMachine.evaluate(snapshot)` → `TouchBarController.update(state, snapshot)` → repaints each cached item + tray badge.

On any of: skin YAML change, manual "重新挂载 Touch Bar" menu item, or cycle-skin button — `AppDelegate` calls `touchBarController.reload()` which re-runs `update(...)` then re-`present()`s the modal so color changes take effect immediately.

## Conventions & gotchas

- All UI types are `@MainActor` and touch the system modal only from the main thread; the `Timer.scheduledTimer` block uses `[weak self]` and assumes the main RunLoop (`.common` mode is added explicitly in `StatusReader.start`).
- `HermesState.colorKey` (`HermesTouchBar/Models/State.swift:80`) is the contract between state semantics and skin palettes — if you add a state, add the corresponding color key to `HermesSkin.default`.
- `SkinProvider` watches the skins directory with `O_EVTONLY` + `DispatchSource`; it is intentionally not `FSEvents`. Adding a new skin takes effect on the next event tick (typically < 1 s).
- `QuickActions` stores its callback dispatch table on `QuickActions.cbHandlers` because the Carbon `EventHandlerUPP` is a C closure and cannot capture Swift state. Keep that table in sync inside `register(key:action:)`.
- The private-API bridge assumes macOS 13.0+ and only links `AppKit` from the Obj-C side; Swift side adds `Carbon` and `sqlite3`. There is no entitlements file (`CODE_SIGN_ENTITLEMENTS` is empty in `project.yml`); ad-hoc signing only.
- `project.yml` is for XcodeGen regeneration if a `.xcodeproj` is desired, but the working build path is `scripts/build.sh`. Do not check in a generated `.xcodeproj` unless you also migrate build flow to `xcodebuild`.
- There is no `.cursor/`, `.github/copilot-instructions.md`, or pre-existing `CLAUDE.md`.
