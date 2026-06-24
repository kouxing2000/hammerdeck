# Hammerdeck

A personal macOS **feature platform**: a native Swift app that **embeds a Lua
engine** -- a focused, miniature Hammerspoon. Instead of writing Lua for every
automation, you **toggle features on/off, set their options, and bind each to a
shortcut, a chord (cmd+shift+a, then b), a schedule, or a system event** --
config-and-select, not code.

> Working name. Rename the folder freely; nothing depends on it yet.

## Status

**Milestone 1 done**: the native binary embeds Lua 5.4.7 and the Swift<->Lua
bridge works end-to-end (Swift runs Lua; Lua calls back into Swift).

**Platform v2 + MVP features done (2026-06-10)**: the plugin contract
([`docs/PLUGIN_SYSTEM.md`](docs/PLUGIN_SYSTEM.md)) is implemented -- manifests
with `api = 1`, ACTION vs SERVICE features, and a **scoped ctx** that tears down
everything a feature created when it's disabled. Real features ported from
myHammerSpoon:

- **Sleep Schedule** (service) -- forced sleep with graduated warnings, one-time
  snooze, weekend shift.
- **Break Reminder** (service) -- idle-aware rest reminders with daily work stats.
- **Window Switcher** (action) -- searchable Alt-Tab, most-recently-used first,
  cycle-and-release UX.
- **Turn Off Display When Idle** (service) -- turns the display off after a stretch of no
  activity, with a short warning first.
- **Paste as Plain Text** (2 actions) -- paste without formatting (strips
  fonts/colors/links); can also type the clipboard into paste-blocking fields.
- **Countdown** (2 actions) -- ask for minutes, run a thin progress strip along
  the screen bottom, notify when time is up; pause/resume on its own shortcut.
- **Locate Pointer** (action) -- crosshair around the mouse for a moment,
  following it as it moves; clicks pass through.
- **Bing Daily Wallpaper** (service + action) -- Bing's picture of the day as
  wallpaper on a schedule, with an optional "refresh now" shortcut.
- **Usage Stats** (service) -- wake/sleep sessions and per-app focus time
  (idle excluded) to daily CSVs, with a desktop widget pinned above the
  wallpaper: today's top apps, bars, and a 7-day chart.
- **Text Actions** (action) -- act on the selected text anywhere: open URLs,
  change case, calculate, dictionary lookup; transforms paste back in place.
- **Quick Sites** (action) -- jump to a favorite site: focus its browser tab if
  open, else open it. Per-site routing -- pick the browser, a Chrome profile,
  and whether to open it as a standalone app window. One shortcut, or
  cmd+<number> straight to a row.
- **Window Snap** (7 actions) -- snap the focused window to screen halves,
  toggle maximize/75%, or throw it to the next screen (pointer follows).
- **Window Mode** (2 actions) -- a modal keyboard layer: enter the mode, tap
  WASD/HJKL/corner keys to arrange windows until Escape; undo/redo included.
- **Tab Switcher** (2 actions) -- searchable switcher across all Chrome + Safari
  tabs, most recently used first, with favicons; release the modifier to jump.
- **Clipboard History** (service + action) -- searchable history of copied
  text, pick to paste; password-manager entries are never recorded.
- **Command Palette** (action) -- one hotkey opens a fuzzy launcher over every
  enabled feature's actions; most-used float to the top.

**M2 Slice 1 done (2026-06-10): NO Hammerspoon, anywhere.** Dropped entirely as
a backend -- `adapter.lua` targets the `native.*` bridge (`Native.swift`), and
`swift run` boots the real platform in the standalone binary: Carbon hotkeys,
timers, sleep/wake/lock watchers, UserDefaults settings, and our own toast /
banner / searchable-chooser panels (zero macOS permissions needed). Window
listing/focus is real (AXUIElement, MRU-ordered) -- the one optional
permission: window_switcher prompts for the Accessibility grant when missing.

**Config UI done (same day)**: a menubar hammer icon -- QUICK TRIGGERS: fire
any enabled feature's actions on demand, including dormant ones with no
hotkey bound (enable/disable lives in Settings) -- and a SwiftUI settings window -- the **config-and-select
surface**: every feature gets an on/off toggle and an options form
auto-generated from its typed manifest options. No per-feature UI code; a new
plugin gets its form for free. Option edits apply live (features read options
through ctx.opt; onOptionChange lets stateful features react instantly).
Trigger rebinding (hotkey / chord / schedule / event) ships with conflict
detection and per-action editors.

See [`docs/HANDOVER.md`](docs/HANDOVER.md) for current status + the open backlog.

## Run & test

```bash
swift build       # compiles CLua (vendored Lua 5.4.7) + the Hammerdeck host
swift run         # THE APP: menubar hammer icon appears; first run enables all
lua test/run.lua  # headless platform + feature tests against a fake adapter
```

Click the **hammer icon** in the menubar -> fire any enabled feature's
actions; "Settings…" opens the config window (toggles, options, triggers).
`defaults delete Hammerdeck` resets everything to first-run.
Smoke-boot without grabbing hotkeys: `HAMMERDECK_NO_FIRSTRUN=1 swift run`;
print what the config UI renders: `HAMMERDECK_DUMP_CATALOG=1 swift run`.

## Design

Native Swift host + embedded Lua, meeting at one seam. The big picture (layer
chart, catalog, roadmap) lives in [`docs/ORIENTATION.md`](docs/ORIENTATION.md);
the rationale + adding-a-feature guide in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

The rule that protects every future option: **only the Swift bridge
(`LuaState.swift` + `Native.swift`) and `lua/platform/adapter.lua` may touch
native/OS APIs.** Everything else goes through that seam, so the host stays
swappable and features never see the backend.

## Layout

```
Package.swift              SwiftPM: CLua (engine) + Hammerdeck (host executable)
Sources/
  CLua/                    vendored Lua 5.4.7 C source (see Sources/CLua/VENDOR.md)
  HammerdeckKit/           host library (imported by tests)
    LuaState.swift         the Swift<->Lua bridge -- the seam (Swift side)
    Native.swift           the native.* table -- the ONLY place OS surface grows
    Boot / Panels / StatusBar / SettingsView / DebugControl ...
  Hammerdeck/
    main.swift             thin launcher -> hammerdeckMain()
lua/                       embedded script payload
  hammerdeck.lua           entry point: registers the catalog, binds enabled features
  platform/
    adapter.lua            THE SEAM (Lua side) -- the only Lua file touching the backend
    ctx.lua                scoped, curated ctx -- the plugin API features receive
    manifest.lua           manifest schema + validation (api v1, action|service)
    triggers.lua           universal trigger layer (hotkey | chord | schedule | event)
    registry.lua           available/enabled features; lifecycle + scoped teardown
  features/
    sleep_schedule/        SERVICE feature: quitting-time enforcement
    break_reminder/            SERVICE feature: idle-aware rest reminders
    window_switcher/           ACTION feature: searchable Alt-Tab
test/
  fake_adapter.lua         in-memory adapter (controllable clock)
  run.lua                  headless test suite
docs/
  ORIENTATION.md  HANDOVER.md  ARCHITECTURE.md  PLUGIN_SYSTEM.md
  PLUGIN_IDEAS.md  spoons-index.json
  archive/         frozen records (migration, parity, product research, palette spec)
```
