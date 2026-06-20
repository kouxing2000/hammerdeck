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
`Native.swift` and its `Native+*.swift` domain extensions) and the Lua seam
(`lua/platform/adapter.lua`) may touch native / OS APIs.** `Native.swift` holds
the class, shared state and `installBindings`; the actual OS calls live in
`Native+Triggers/Storage/Panels/Network/Windows/System/Input/Browser.swift`
(same type, extensions). New OS surface grows in whichever `Native+*` slice fits
(or a new one), plus its HotkeyCenter/ChordCenter and the per-panel UI files
(`ChooserPanel.swift`, `BannerPanel.swift`, ...); features and every other
platform module go through the adapter. This keeps the host
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
  `stop`, may also declare `actions`), receives the scoped `ctx` as its native
  surface. Never touches native APIs or the seam/stateful platform modules
  (`adapter`, `ctx`, `registry`, `triggers`, `manifest`, `modal`); MAY `require`
  the pure leaf util modules (`platform.json`, `platform.urls`, `platform.hotkeys`
  -- stateless, no `require` of their own). Get the current time only from
  `ctx.now()` (never bare `os.time()`/`os.date()`, which read the uncontrolled
  wall clock and tests can't drive); `os.date`/`os.time` are fine for FORMATTING
  or decomposing a time you already got from `ctx.now()`.
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
- **Sources/HammerdeckKit/Native.swift + Native+*.swift** (+ HotkeyCenter/ChordCenter
  and per-panel UI files) -- the seam (Swift side): the `native` table the adapter
  calls. `Native.swift` is the class + shared state + `installBindings`; the OS
  calls are grouped into `Native+<domain>.swift` extensions. The only place
  macOS-API surface should grow.
- **Sources/HammerdeckKit/SettingsStore/SettingsView/StatusBar.swift** --
  config UI: menubar (QUICK TRIGGERS: every enabled feature's actions fire on
  demand via registry.runAction; enable/disable lives in Settings only) +
  SwiftUI settings window; forms are GENERATED from
  manifest options (never write per-feature UI code). Reads the catalog via
  `registry.describe()` over `LuaState.eval`; writes the same
  `hammerdeck.opt.*` defaults keys `ctx.opt` reads. Menubar shortcuts render
  via native `keyEquivalent` -- the ONLY thing that sits flush-right with the
  submenu arrows (an `attributedTitle` shortcut can't reach that column; it
  always floats a fixed gap short). The global hotkey already fires the action,
  so `runAction` ignores keyboard-origin invocations (`NSApp.currentEvent` is a
  key/flags event) to avoid double-firing; non-key triggers (schedule/chord/
  event) have no key form and show no menu shortcut.
- **Sources/Hammerdeck/main.swift** -- thin launcher only (calls
  `hammerdeckMain()`); all logic lives in the Kit so tests can import it.
- **Tests/HammerdeckTests/** -- integration tests against the REAL bridge
  (no fake adapter): boots the Lua platform in-process via `swift test`.
- **Sources/CLua/** -- vendored Lua 5.4.7. Do NOT hand-edit. See `Sources/CLua/VENDOR.md`.

## Build / run

```bash
swift build       # compiles CLua + HammerdeckKit + the launcher
swift run         # boots the platform in the native host (the real app)
lua test/run.lua     # headless platform + feature tests (fake adapter, Homebrew Lua -- fast inner loop)
scripts/test-lua.sh  # SAME suite on the vendored 5.4.7 (exact embedded engine) -- run before committing Lua / in CI
swift test           # integration tests on the REAL bridge (run after Swift/seam changes)
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

Pixel fixes -- probe before iterating (the project instance of the global
"probe the constraint" rule): a native-AppKit visual fix that misses once is
usually a HARD constraint, not one tweak away. The canonical example is the
menubar shortcut column -- only a native `keyEquivalent` sits flush-right with
the submenu arrows; an `attributedTitle` shortcut can't reach that column and
always floats a fixed gap short (see the StatusBar note in the layer map). When
a menubar/panel pixel fix misses, read the layout model or run ONE throwaway
`scripts/shot.sh` probe to learn what the mechanism physically can/can't do,
pick it once, then implement -- don't trial-and-error.

Lua syntax check: `luac -p lua/**/*.lua`. Version skew: `lua test/run.lua` runs
on Homebrew Lua (currently 5.5) while the embedded engine is vendored 5.4.7 --
keep all Lua code 5.4-compatible. `scripts/test-lua.sh` closes the gap: it
compiles a standalone interpreter from `Sources/CLua` (the exact embedded
5.4.7, same `-DLUA_USE_MACOSX` flag) and runs the same suite, so a 5.4
incompatibility that 5.5 happens to accept fails there. The suite's final line
prints the live `_VERSION` so you can see which engine ran. SourceKit may show "No such module
'CLua'/'PackageDescription'" in the editor -- stale index noise; `swift build`
is the source of truth.

Lua type-friendliness: `.luarc.json` pins the language server (runtime 5.4,
`require` path resolution, the host-injected `native` global). Annotate
cross-file functions and non-obvious table shapes with LuaLS `---@` annotations
(`platform/json.lua` is the worked example). Array-vs-object shape that crosses
the Swift bridge or `json.encode` is carried by the `__jsontype` metatable tag
(`json.asObject`/`asArray`), honored by both `json.lua` and `LuaState.any`; a
table mixing array entries with string keys is rejected loudly, never dropped.

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
