# Hammerdeck

A personal macOS **feature platform**: a native Swift app embedding a Lua engine
(a focused mini-Hammerspoon). Lowers the bar from "write Lua" to
**config-and-select**: toggle features, set options, bind each to a
shortcut/schedule/event. Single-author, first-party catalog -- NOT a third-party
marketplace.

Swift is the host (lifecycle, native macOS APIs, UI). Lua is the embedded script
payload (the feature platform). They meet at one bridge.

## The one inviolable rule

**Only the Swift bridge (`Sources/Hammerdeck/LuaState.swift`) and the Lua seam
(`lua/platform/adapter.lua`) may touch native / OS APIs.** Features and every
other platform module go through the adapter. This keeps the host swappable and
the layers clean. If you need a native call elsewhere, add it to the bridge +
adapter, never reach past the seam.

> Current state (M2 Slice 1 done, 2026-06-10): **no Hammerspoon anywhere** --
> dropped entirely as a backend by owner decision. `adapter.lua` targets the
> `native.*` table that `Sources/Hammerdeck/Native.swift` injects; `swift run`
> boots `lua/hammerdeck.lua` and the features run in the standalone binary.
> Pending: window listing (AXUIElement, M2 Slice 2) -- window_jump degrades to
> an alert until then. See docs/HANDOVER.md.

## Layers (top depends on bottom only)

`lua/features/*` -> `registry` -> `triggers` / `manifest` -> `adapter` (Lua seam)
-> `LuaState.swift` (Swift bridge) -> macOS APIs

- **lua/features/** -- logic only; declares a manifest (`api = 1`; ACTION =
  `defaultTrigger`+`action(ctx)`, SERVICE = `start(ctx)`+optional `stop`),
  receives only the scoped `ctx` (no raw adapter; no `os.time()` -- use
  `ctx.now()`). Never touches native APIs or platform internals.
- **lua/platform/manifest.lua** -- validates a feature's declared shape; resolves defaults.
- **lua/platform/triggers.lua** -- declarative trigger spec -> live binding. Any
  trigger can fire any action (the core idea). Types: hotkey, schedule
  (everyMin / at), event (sleep|wake|screenLock|screenUnlock).
- **lua/platform/registry.lua** -- registers features, persists enabled-state +
  option values per id, runs lifecycle (bind trigger / start), scoped teardown.
- **lua/platform/ctx.lua** -- builds the scoped, curated ctx (the plugin API);
  every handle a feature creates is tracked and stopped on disable. Contract
  design: `docs/PLUGIN_SYSTEM.md`.
- **lua/platform/adapter.lua** -- the seam (Lua side); every binding it returns
  is a handle with `.stop()`.
- **Sources/Hammerdeck/LuaState.swift** -- the bridge mechanics: owns the Lua
  state, runs Lua, callback refs, table readers, `eval`.
- **Sources/Hammerdeck/Native.swift** (+ HotkeyCenter/Panels helpers) -- the
  seam (Swift side): the `native` table the adapter calls. The only place
  macOS-API surface should grow.
- **Sources/Hammerdeck/SettingsStore/SettingsView/StatusBar.swift** -- config
  UI: menubar + SwiftUI settings window; forms are GENERATED from manifest
  options (never write per-feature UI code). Reads the catalog via
  `registry.describe()` over `LuaState.eval`; writes the same
  `hammerdeck.opt.*` defaults keys `ctx.opt` reads.
- **Sources/CLua/** -- vendored Lua 5.4.7. Do NOT hand-edit. See `Sources/CLua/VENDOR.md`.

## Build / run

```bash
swift build       # compiles CLua + Hammerdeck
swift run         # boots the platform in the native host (the real app)
lua test/run.lua  # headless platform + feature tests (fake adapter, run after Lua changes)
```

Smoke test without grabbing hotkeys: `HAMMERDECK_NO_FIRSTRUN=1 swift run`.
Settings live in the `Hammerdeck` defaults domain (`defaults read Hammerdeck`;
`defaults delete Hammerdeck` resets to first-run).

Lua syntax check: `luac -p lua/**/*.lua`. Note the version skew: the test suite
runs on Homebrew Lua (currently 5.5) while the embedded engine is vendored
5.4.7 -- keep all Lua code 5.4-compatible. SourceKit may show "No such module
'CLua'/'PackageDescription'" in the editor -- stale index noise; `swift build`
is the source of truth.

## Adding a feature

ACTION feature: copy `lua/features/window_jump/`. SERVICE feature: copy
`lua/features/sleep_schedule/` (directory form; `init.lua` returns the
manifest -- a flat `features/<name>.lua` file also works for trivial features).
Features are **autodiscovered** by scanning `lua/features/` -- just drop the
folder in (no catalog to edit; menubar "Reload Features" or a restart picks it
up). Then cover its main flow in `test/run.lua` (register it there directly --
the test harness uses its own catalog, not disk discovery).

## Status / roadmap

`docs/HANDOVER.md` is the living status + milestone backlog -- read it first.
`docs/ARCHITECTURE.md` is the design rationale. Don't duplicate the backlog here.
