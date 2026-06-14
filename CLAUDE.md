# Hammerdeck

A personal macOS **feature platform**: a native Swift app embedding a Lua engine
(a focused mini-Hammerspoon). Lowers the bar from "write Lua" to
**config-and-select**: toggle features, set options, bind each to a
shortcut/schedule/event. Single-author, first-party catalog -- NOT a third-party
marketplace.

Swift is the host (lifecycle, native macOS APIs, UI). Lua is the embedded script
payload (the feature platform). They meet at one bridge.

## The one inviolable rule

**Only the Swift bridge (`Sources/HammerdeckKit/LuaState.swift` +
`Native.swift`) and the Lua seam (`lua/platform/adapter.lua`) may touch
native / OS APIs.** New OS surface grows in `Native.swift` (+ its
HotkeyCenter/ChordCenter/Panels helpers); features and every other platform
module go through the adapter. This keeps the host
swappable and the layers clean. If you need a native call elsewhere, add it to
the bridge + adapter, never reach past the seam.

> Current state (2026-06-11): **no Hammerspoon anywhere** -- dropped entirely
> as a backend by owner decision. `adapter.lua` targets the `native.*` table
> that `Sources/HammerdeckKit/Native.swift` injects; `swift run` boots
> `lua/hammerdeck.lua` (features autodiscovered from `lua/features/`).
> Window listing is REAL now (AXUIElement; window_switcher prompts for the
> Accessibility grant when missing). See docs/HANDOVER.md.

## Layers (top depends on bottom only)

`lua/features/*` -> `registry` -> `triggers` / `manifest` -> `adapter` (Lua seam)
-> `LuaState.swift` (Swift bridge) -> macOS APIs

- **lua/features/** -- logic only; declares a manifest (`api = 1`; ACTIONS =
  `actions = {{id, label, defaultTrigger?, run}, ...}` -- one plugin, several
  independently rebindable shortcuts; single-action sugar
  `defaultTrigger`+`action(ctx)` still works; SERVICE = `start(ctx)`+optional
  `stop`, may also declare `actions`), receives only the scoped `ctx` (no raw
  adapter; no `os.time()` -- use `ctx.now()`). Never touches native APIs or
  platform internals.
- **lua/platform/manifest.lua** -- validates a feature's declared shape; resolves defaults.
- **lua/platform/triggers.lua** -- declarative trigger spec -> live binding. Any
  trigger can fire any action (the core idea). Types: hotkey, chord (prefix
  hotkey + an ordered follow-key sequence, e.g. cmd+shift+a then b -- a modal
  layer over Carbon in ChordCenter.swift, permission-free), schedule (everyMin /
  at), event (sleep|wake|screenLock|screenUnlock|screenChanged).
- **lua/platform/modal.lua** -- modal hotkey groups (enter a keyboard mode:
  bare-key hotkeys live until Escape/exit; banner legend). Pure Lua over
  adapter primitives; reach it via ctx.modal().
- **lua/platform/registry.lua** -- registers features, persists enabled-state +
  option values per id, runs lifecycle (bind trigger / start), scoped teardown.
- **lua/platform/ctx.lua** -- builds the scoped, curated ctx (the plugin API);
  every handle a feature creates is tracked and stopped on disable. A feature
  that declares `capabilities = {"commands"}` gets privileged cross-feature
  reach injected here (`ctx.commands()` / `ctx.runCommand()`, least-privilege --
  powers the command palette). Contract design: `docs/PLUGIN_SYSTEM.md`.
- **lua/platform/adapter.lua** -- the seam (Lua side); every binding it returns
  is a handle with `.stop()`.
- **Sources/HammerdeckKit/LuaState.swift** -- the bridge mechanics: owns the
  Lua state, runs Lua, callback refs, table readers, `eval`.
- **Sources/HammerdeckKit/Native.swift** (+ HotkeyCenter/ChordCenter/Panels helpers) -- the
  seam (Swift side): the `native` table the adapter calls. The only place
  macOS-API surface should grow.
- **Sources/HammerdeckKit/SettingsStore/SettingsView/StatusBar.swift** --
  config UI: menubar (QUICK TRIGGERS: every enabled feature's actions fire on
  demand via registry.runAction; enable/disable lives in Settings only) +
  SwiftUI settings window; forms are GENERATED from
  manifest options (never write per-feature UI code). Reads the catalog via
  `registry.describe()` over `LuaState.eval`; writes the same
  `hammerdeck.opt.*` defaults keys `ctx.opt` reads.
- **Sources/Hammerdeck/main.swift** -- thin launcher only (calls
  `hammerdeckMain()`); all logic lives in the Kit so tests can import it.
- **Tests/HammerdeckTests/** -- integration tests against the REAL bridge
  (no fake adapter): boots the Lua platform in-process via `swift test`.
- **Sources/CLua/** -- vendored Lua 5.4.7. Do NOT hand-edit. See `Sources/CLua/VENDOR.md`.

## Build / run

```bash
swift build       # compiles CLua + HammerdeckKit + the launcher
swift run         # boots the platform in the native host (the real app)
lua test/run.lua  # headless platform + feature tests (fake adapter, run after Lua changes)
swift test        # integration tests on the REAL bridge (run after Swift/seam changes)
```

`swift test` is QUIET by default: the 6 tests that show real panels or
synthesize system keystrokes are SKIPPED -- otherwise they flash dialogs and
type into whatever app the user has focused. Run the full set ONLY when the user
is away from the keyboard: `HAMMERDECK_UI_TESTS=1 swift test` (the
CGEvent-synthesis ones additionally need Accessibility on the terminal). All
other integration tests run anywhere.

Smoke test without grabbing hotkeys: `HAMMERDECK_NO_FIRSTRUN=1 swift run`.
Settings live in the `Hammerdeck` defaults domain (`defaults read Hammerdeck`;
`defaults delete Hammerdeck` resets to first-run).

Visual check (real pixels -- the one thing tests can't do): `scripts/app.sh
start` opens a debug Lua control channel; `scripts/control.sh '<lua>'` drives
the live app (e.g. open the palette) and `scripts/shot.sh out.png` screenshots
it for you to read. The capturing terminal needs Screen Recording, or the
panels are missing from the image. Don't restart the user's running instance or
run the UI tests while they may be at the keyboard -- ask first.

Lua syntax check: `luac -p lua/**/*.lua`. Note the version skew: the test suite
runs on Homebrew Lua (currently 5.5) while the embedded engine is vendored
5.4.7 -- keep all Lua code 5.4-compatible. SourceKit may show "No such module
'CLua'/'PackageDescription'" in the editor -- stale index noise; `swift build`
is the source of truth.

## Adding a feature

ACTION feature: copy `lua/features/window_switcher/`. SERVICE feature: copy
`lua/features/sleep_schedule/` (directory form; `init.lua` returns the
manifest -- a flat `features/<name>.lua` file also works for trivial features).
Features are **autodiscovered** by scanning `lua/features/` -- just drop the
folder in (no catalog to edit; menubar "Reload Features" or a restart picks it
up). Then cover its main flow in `test/run.lua` (register it there directly --
the test harness uses its own catalog, not disk discovery).

## Status / roadmap

`docs/ORIENTATION.md` is the step-back visual map (architecture, catalog,
roadmap) -- start there for the big picture. `docs/HANDOVER.md` is the ONE
living status + backlog doc -- read it for the truth (its doc map explains
which docs are living / reference / archived). `docs/ARCHITECTURE.md` is the
design rationale. Don't duplicate the backlog here.
