# Hammerdeck

A personal macOS **feature platform**: a native Swift app embedding a Lua engine
(a focused mini-Hammerspoon). Lowers the bar from "write Lua" to
**config-and-select**: toggle features, set options, bind each to a
shortcut/schedule/event. Single-author, first-party catalog -- NOT a third-party
marketplace.

Swift is the host (lifecycle, native macOS APIs, UI). Lua is the embedded script
payload (the feature platform). They meet at one bridge.

## The one inviolable rule

**Only the Swift bridge (`app/platform/swift/LuaState.swift` +
`Native.swift` and its `Native+*.swift` domain extensions) and the Lua seam
(`app/platform/lua/adapter.lua`) may touch native / OS APIs.** `Native.swift` holds
the class, shared state and `installBindings`; the actual OS calls live in
`Native+Triggers/Storage/Panels/Network/Windows/System/Input/Browser.swift`
(same type, extensions). New OS surface grows in whichever `Native+*` slice fits
(or a new one), plus its HotkeyCenter/ChordCenter and the per-panel UI files
(`ChooserPanel.swift`, `BannerPanel.swift`, ...); features and every other
platform module go through the adapter. This keeps the host
swappable and the layers clean. If you need a native call elsewhere, add it to
the bridge + adapter, never reach past the seam.

**One sanctioned exception -- the feature-contributed host reporter.** Just as a
feature may contribute a `swift/` host page, it may contribute a `lua/` *host
reporter* (today: `usage_stats/lua/report.lua`): a host-CALLABLE module that runs
OUTSIDE any `ctx` -- invoked by the host, and working even when the feature is
DISABLED (it reads data the feature left behind, e.g. usage CSVs that outlive any
run). It has no enable lifecycle a `ctx` could attach to, so it may touch the
seam (`require "platform.adapter"`) and the wall clock (`os.date`/`os.time`)
DIRECTLY -- the two rules below that normally bind feature code. This is a
narrow, declared role, NOT a loophole: such a module must self-declare it in its
header (as report.lua does -- "host-callable historical reporter, NOT feature
logic"), so the exemption is explicit and greppable rather than an unspoken
special case. A reporter is still pure Lua over the adapter -- it reaches the OS
only through the seam, never `native.*`.

> Current state (2026-06-24): **no Hammerspoon** -- dropped as a backend by
> owner decision. **Co-located layout** (refactor of 2026-06-24): everything
> lives under `app/` -- `app/platform/{lua,swift}/`, and each feature is
> `app/features/<id>/` with a `feature.json` (declarative identity/presentation),
> a `lua/` subfolder (the plugin code), and an optional `swift/` subfolder
> (native UI it contributes). `app/loader.lua` installs a custom
> `package.searcher` so the stable require names
> (`require("features.usage_stats.store")`, `require("platform.adapter")`)
> resolve into those `lua/` subfolders UNCHANGED. `adapter.lua` targets the
> `native.*` table that `Native.swift` injects; `swift run` boots
> `app/hammerdeck.lua` (features autodiscovered by scanning `app/features/` for a
> `<id>/lua/init.lua`). Window listing is REAL (AXUIElement; window_switcher
> prompts for the Accessibility grant when missing). See docs/HANDOVER.md.

## Layers (top depends on bottom only)

`app/features/*/lua` -> `registry` -> `triggers` / `manifest` -> `adapter` (Lua seam)
-> `LuaState.swift` (Swift bridge) -> macOS APIs

**`app/platform/lua/` tiers** (the dir is FLAT; this is the layering `ls` does
not show): **SEAM** = `adapter.lua` (the only file here that reaches `native.*`).
**CORE / stateful** = `ctx`, `registry`, `triggers`, `manifest`, `modal`,
`window_ops` (hold state + lifecycle; features never `require` them).
`window_ops` owns the live focused-window move + "pointer-follows-window" policy
(`ctx.window.setFrame` delegates to it); the registry injects its pointer-follow
predicate at boot. **SUBSYSTEM** = the automation rules engine
(`rules` + `signals` + `effects` -- domain logic that reaches the OS only through
registry/adapter, never the seam), plus `i18n` (locale-injected, internal).
`favicons` sits in this tier structurally but is a **pure factory subsystem** a
feature MAY `require` (it needs only the `urls` leaf util, used as
`favicons.new(ctx)`) -- a sibling to the leaf utils, NOT a zero-`require` leaf
itself (so it stays OFF the leaf-guard list). **LEAF UTILS** =
`json`, `urls`, `hotkeys`, `windows`, `cyclingChooser` (the invariant is ZERO
`require`, NOT purity -- they may call native, but only via a `ctx` passed in, e.g.
`windows.focusedOrAlert`; the only ZERO-`require` platform modules a feature may
`require` -- `favicons` above is the one require-ful module also allowed; a
test-suite guard fails if any of them grows a `require`). The `ctx` surface is
namespaced into domain sub-tables (`ctx.window.*` / `ctx.screen.*` /
`ctx.mouse.*`) -- Phase 1 of `docs/specs/CTX_DOMAIN_NAMESPACES_SPEC.md`, landed
2026-06-29. The remaining Phase 2 (porting Hammerspoon's pure-Lua tiling/grid
algorithms onto `platform.windows` + curated `ctx.window.*` helpers) is still
pending.

- **app/features/<id>/** -- one feature, three co-located parts: `feature.json`
  (DECLARATIVE identity/presentation -- name, version, description, category,
  context, and optional requires/recommended/page; no code), `lua/` (the plugin
  code: `init.lua` returns the manifest table -- `id` (the anchor) + `api` +
  behavior), and an optional `swift/` (native UI the feature contributes, e.g.
  usage_stats' report page). The registry OVERLAYS feature.json onto the manifest
  at register time. The `lua/init.lua` declares (`api = 1`; ACTIONS =
  `actions = {{id, label, defaultTrigger?, automatable?, run}, ...}` -- one plugin,
  several independently rebindable shortcuts; single-action sugar
  `defaultTrigger`+`action(ctx)` still works; SERVICE = `start(ctx)`+optional
  `stop`, may also declare `actions`), and receives the scoped `ctx` as its native
  surface. Never touches native APIs or the seam/stateful platform modules
  (`adapter`, `ctx`, `registry`, `triggers`, `manifest`, `modal`, `window_ops`);
  MAY `require` the pure leaf util modules (`platform.json`, `platform.urls`,
  `platform.hotkeys`, `platform.windows`, `platform.cyclingChooser` -- stateless,
  no `require` of their own), PLUS the pure factory subsystem `platform.favicons`
  -- a sibling category to the leaf utils (it requires only the `urls` leaf util
  and is used via `favicons.new(ctx)`), NOT itself a zero-`require` leaf util, so
  it must NOT join the leaf-guard list. Get the current time only from
  `ctx.now()` (never bare `os.time()`/`os.date()`, which read the uncontrolled
  wall clock and tests can't drive); `os.date`/`os.time` are fine for FORMATTING
  or decomposing a time you already got from `ctx.now()`. (Exception: a
  feature-contributed *host reporter* -- see "The one inviolable rule" -- runs
  outside `ctx`, so it has no `ctx.now()` and reads the wall clock directly.)
- **app/loader.lua** -- installs the `package.searcher` that maps the stable
  `platform.*` / `features.<id>.*` require names onto their `lua/` subfolders, so
  the co-located layout needs zero require rewrites. Exposes `appdir` (the
  registry uses it to locate `<id>/feature.json`). The `swift/` sibling is
  invisible to `require`.
- **app/platform/lua/manifest.lua** -- validates a feature's MERGED shape
  (feature.json overlaid onto the lua manifest by the registry); resolves defaults.
- **app/platform/lua/triggers.lua** -- declarative trigger spec -> live binding. Any
  trigger can fire any action (the core idea). Types split into MANUAL (a human
  presses keys, so live UI context is meaningful) -- hotkey, chord (prefix
  hotkey + an ordered follow-key sequence, e.g. cmd+shift+a then b -- a modal
  layer over Carbon in ChordCenter.swift, permission-free) -- and AUTOMATED
  (fires with nobody present, no context) -- schedule (everyMin / at), event
  (sleep|wake|screenLock|screenUnlock|screenChanged). An action takes automated
  triggers ONLY if it declares `automatable = true` (default false -- most
  actions read the live selection/window/clipboard and are nonsensical fired
  unattended); the Settings picker hides the automated types for a non-
  automatable action, and the registry seam refuses such a spec on rebind (and
  silently ignores a stale stored one on load -- falling back to the default).
  State-changers that need no context (refresh wallpaper, toggle a setting) opt in.
- **app/platform/lua/modal.lua** -- modal hotkey groups (enter a keyboard mode:
  bare-key hotkeys live until Escape/exit; banner legend). Pure Lua over
  adapter primitives; reach it via ctx.modal().
- **app/platform/lua/registry.lua** -- registers features, persists enabled-state +
  option values per id, runs lifecycle (bind trigger / start), scoped teardown.
- **app/platform/lua/ctx.lua** -- builds the scoped, curated ctx (the plugin API);
  every handle a feature creates is tracked and stopped on disable. A feature
  that declares `capabilities = {"commands"}` gets privileged cross-feature
  reach injected here (`ctx.commands()` / `ctx.runCommand()`, least-privilege --
  powers the command palette). Contract design: `docs/PLUGIN_SYSTEM.md`.
- **app/platform/lua/adapter.lua** -- the seam (Lua side); every binding it returns
  is a handle with `.stop()`.
- **app/platform/swift/LuaState.swift** -- the bridge mechanics: owns the
  Lua state, runs Lua, callback refs, table readers, `eval`.
- **app/platform/swift/Native.swift + Native+*.swift** (+ HotkeyCenter/ChordCenter
  and per-panel UI files) -- the seam (Swift side): the `native` table the adapter
  calls. `Native.swift` is the class + shared state + `installBindings`; the OS
  calls are grouped into `Native+<domain>.swift` extensions. The only place
  macOS-API surface should grow.
- **app/platform/swift/SettingsStore/SettingsView/StatusBar.swift** --
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

`swift test` is QUIET by default: the tests that show real panels, synthesize
system keystrokes, or touch the login Keychain are SKIPPED (all gated behind the
`requireUITests()` opt-in) -- otherwise they flash dialogs, type into whatever
app the user has focused, or pop a Keychain prompt. Run the full set ONLY when
the user is away from the keyboard: `HAMMERDECK_UI_TESTS=1 swift test` (the
CGEvent-synthesis ones additionally need Accessibility on the terminal). Some of
those also carry a capability gate (Accessibility trust, an unlocked session, a
Chrome profile) and skip-not-fail when the environment can't support them, so
the exact skip count varies by machine -- that's adaptive, not flaky. All other
integration tests run anywhere.

Smoke test without grabbing hotkeys: `HAMMERDECK_NO_FIRSTRUN=1 swift run`.
Settings live in the `Hammerdeck` defaults domain (`defaults read Hammerdeck`;
`defaults delete Hammerdeck` resets to first-run).

**Logging / auditability.** `ctx.log(...)` (features) and the seam's `log` go to
stdout AND a rotating daily file under
`~/Library/Application Support/Hammerdeck/logs/YYYY-MM-DD.log` (14-day retention;
"Open Logs" in the menubar; `scripts/app.sh logs` tails the launcher stdout).
A feature MUST keep PERMANENT, terse `ctx.log` traces of its meaningful runtime
DECISIONS and state transitions -- enable/disable, and each branch a stateful
loop takes (e.g. window_deck logs on/off, promote, drop, peek-stay, and a
suppressed settling-echo). These are the audit trail for "what did the logic
actually decide and do", so a live bug (a focus fight, a wrong promotion) is
diagnosable from the log ALONE, without re-instrumenting and re-reproducing --
which is dear when a run needs real windows / an unlocked screen. Keep them in;
do NOT strip them as "debug noise" once a fix lands (that is the global rule's
temporary `THROWAWAY` debug prints, a different thing). Log the decision + the
key identity (a window key, a mode), never a tight per-frame spam.

Visual check (real pixels -- the one thing tests can't do): `scripts/app.sh
start` opens a debug Lua control channel; `scripts/control.sh '<lua>'` drives
the live app (e.g. open the palette) and `scripts/shot.sh out.png` screenshots
it for you to read. The capturing terminal needs Screen Recording, or the
panels are missing from the image. Don't restart the user's running instance or
run the UI tests while they may be at the keyboard -- ask first.

To screenshot the **SwiftUI Settings window** (the chord/trigger editors, option
forms -- NOT a native panel, so the Lua eval channel can't reach it), use the
host-UI deep link: `scripts/control.sh '@settings:<featureId>'` opens Settings
straight to that feature's detail (e.g. `@settings:count_down`), then capture
with **`scripts/control.sh '@shot:<path>'`** -- the app renders its OWN detail
form to a PNG in-process (DebugShot). Strongly prefer `@shot` over
`scripts/shot.sh` (whole-screen screencapture) for the Settings window: it needs
no Screen Recording, does not care if the window is frontmost / occluded / off-
screen, and captures the scroll view's FULL content height, so options below the
fold (long forms, an expanded row editor) are included without scrolling. Bare
`@settings` just opens the tab. (DebugControl intercepts `@settings` / `@shot`
before the Lua eval; DEBUG-only.) `scripts/shot.sh` stays the tool for native
panels (chooser/banner), which live outside the Settings window. Reach for this
BEFORE blind-iterating on config-UI pixels -- driving the live window via
osascript clicks/scrolls is a rabbit hole (focus theft, below-the-fold content);
in-process self-capture sidesteps all of it.

Pixel fixes -- probe before iterating (the project instance of the global
"probe the constraint" rule): a native-AppKit visual fix that misses once is
usually a HARD constraint, not one tweak away. The canonical example is the
menubar shortcut column -- only a native `keyEquivalent` sits flush-right with
the submenu arrows; an `attributedTitle` shortcut can't reach that column and
always floats a fixed gap short (see the StatusBar note in the layer map). When
a menubar/panel pixel fix misses, read the layout model or run ONE throwaway
`scripts/shot.sh` probe to learn what the mechanism physically can/can't do,
pick it once, then implement -- don't trial-and-error.

Z-order (a second hard constraint, learned via window_deck's "return blink",
2026-07-02): other apps' windows CANNOT be reordered atomically -- AXRaise is
top-of-stack only (no insert-below), and some apps (VSCode, Chrome) ACTIVATE
the window they're asked to raise, so any multi-window raise pass flashes
whichever member applies mid-pass over the intended top window. Never raise
more than one window in a user-visible moment: bring at most ONE window
forward (the one the user focused -- their own click already fronts it), and
defer multi-window z-repair to beat landings, where ring flights + window
motion cover the churn (window_deck's recleanIfPeeked is the worked example).

Lua syntax check: `luac -p app/**/*.lua`. Version skew: `lua test/run.lua` runs
on Homebrew Lua (currently 5.5) while the embedded engine is vendored 5.4.7 --
keep all Lua code 5.4-compatible. `scripts/test-lua.sh` closes the gap: it
compiles a standalone interpreter from `Sources/CLua` (the exact embedded
5.4.7, same `-DLUA_USE_MACOSX` flag) and runs the same suite, so a 5.4
incompatibility that 5.5 happens to accept fails there. The suite's final line
prints the live `_VERSION` so you can see which engine ran. SourceKit may show "No such module
'CLua'/'PackageDescription'" in the editor -- stale index noise; `swift build`
is the source of truth.

Lua type-friendliness: `.luarc.json` pins the language server (runtime 5.4,
the host-injected `native` global, and the type-mismatch diagnostics escalated
to Error). Annotate cross-file functions and non-obvious table shapes with
LuaLS `---@` annotations (`platform/json.lua` is the worked example; string
token sets get a real `---@enum`, see `ScreenDir` in `platform/windows.lua`).
The annotations are ENFORCED, not editor-only: `scripts/check-lua-types.sh`
runs LuaLS over the workspace at Error level (CI runs it per push). It first
regenerates `.luals-stubs/` -- 2-line `---@meta` redirects mapping the
loader's stable require names (`platform.*`, `features.<id>.*`) onto the
co-located `lua/` files. WITHOUT those stubs the server resolves no
cross-module require at all (the custom searcher's prefix mapping is
inexpressible in `runtime.path`) and every cross-file contract silently goes
unchecked -- so if requires seem un-typechecked, run the script to refresh
the stubs (generated + gitignored; never hand-edit). Array-vs-object shape
that crosses the Swift bridge or `json.encode` is carried by the `__jsontype`
metatable tag (`json.asObject`/`asArray`), honored by both `json.lua` and
`LuaState.any`; a table mixing array entries with string keys is rejected
loudly, never dropped.

## Adding a feature

ACTION feature: copy `app/features/window_switcher/`. SERVICE feature: copy
`app/features/sleep_schedule/`. A feature is a folder
`app/features/<id>/` with: `feature.json` (identity/presentation -- name,
version, description, category, context, optional requires/recommended/page),
`lua/init.lua` (returns the manifest table: `id` + `api` + behavior), and an
optional `swift/` (native UI; register it in `FeaturePageRegistry` and declare a
`page` in feature.json). Features are **autodiscovered** by scanning
`app/features/` for a `<id>/lua/init.lua` -- just drop the folder in (no catalog
to edit; menubar "Reload Features" or a restart picks it up). To keep `swift
build` warning-free, also add the new feature to `Package.swift`'s
`HammerdeckKit` target: a Lua-only feature -> add `"features/<id>"` to `exclude`;
a feature WITH a `swift/` -> add `"features/<id>/swift"` to `sources` and
`"features/<id>/lua"` + `"features/<id>/feature.json"` to `exclude`. (SwiftPM
scans the whole `app/` subtree for resources; skipping the exclude just brings
back the harmless "N unhandled files" warning -- the feature still loads.) Then cover its
main flow in `test/run.lua` (register it there directly -- the test harness uses
its own catalog, not disk discovery; a real feature's `feature.json` is read
from disk via io, so its metadata merges in tests too). If an action is a
context-free state-changer a user might want to schedule or fire on a system
event (e.g. bing_daily's "Refresh wallpaper now", which ships with a schedule
as its default trigger), mark it `automatable = true`;
otherwise it stays manual-only (hotkey/chord). An automated `defaultTrigger`
requires `automatable = true` -- manifest.validate rejects the mismatch.

## Status / roadmap

`docs/HANDOVER.md` is the ONE living status + backlog doc -- read it for the
truth (its doc map explains which docs are living / reference / archived).
`docs/ARCHITECTURE.md` is the design rationale; `docs/actions/` holds the
per-domain launch + code action lists (index: `docs/actions/README.md`).
Don't duplicate the backlog here.
