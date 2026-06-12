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
- **Rest Timer** (service) -- idle-aware rest reminders with daily work stats.
- **Window Jump** (action) -- searchable Alt-Tab, most-recently-used first,
  cycle-and-release UX.
- **Idle Display Off** (service) -- turns the display off after a stretch of no
  activity, with a short warning first.
- **Clean Clipboard** (action) -- rewrites the clipboard as trimmed plain text
  (strips formatting); optionally turns newlines into commas.
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
- **Jump to Site** (action) -- focus the browser tab for a configured site
  (or open it) with one shortcut.

**M2 Slice 1 done (2026-06-10): NO Hammerspoon, anywhere.** Dropped entirely as
a backend -- `adapter.lua` targets the `native.*` bridge (`Native.swift`), and
`swift run` boots the real platform in the standalone binary: Carbon hotkeys,
timers, sleep/wake/lock watchers, UserDefaults settings, and our own toast /
banner / searchable-chooser panels (zero macOS permissions needed). Window
listing/focus is real (AXUIElement, MRU-ordered) -- the one optional
permission: window_jump prompts for the Accessibility grant when missing.

**Config UI done (same day)**: a menubar hammer icon (quick feature toggles,
Settings..., Quit) and a SwiftUI settings window -- the **config-and-select
surface**: every feature gets an on/off toggle and an options form
auto-generated from its typed manifest options. No per-feature UI code; a new
plugin gets its form for free. Option edits apply live (features read options
through ctx.opt). Trigger rebinding UI is next.

See [`docs/HANDOVER.md`](docs/HANDOVER.md) for the full status + milestone backlog.

## Run & test

```bash
swift build       # compiles CLua (vendored Lua 5.4.7) + the Hammerdeck host
swift run         # THE APP: menubar hammer icon appears; first run enables all
lua test/run.lua  # headless platform + feature tests against a fake adapter
```

Click the **hammer icon** in the menubar -> toggles per feature, "Settings…"
opens the config window.
`defaults delete Hammerdeck` resets everything to first-run.
Smoke-boot without grabbing hotkeys: `HAMMERDECK_NO_FIRSTRUN=1 swift run`;
print what the config UI renders: `HAMMERDECK_DUMP_CATALOG=1 swift run`.

## Design

Native Swift host + embedded Lua. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
The rule that protects every future option: **only the Swift bridge
(`LuaState.swift`) and `lua/platform/adapter.lua` may touch native/OS APIs.**
Everything else goes through the adapter, so the host stays swappable and features
never see the backend.

## Layout

```
Package.swift              SwiftPM: CLua (engine) + Hammerdeck (host executable)
Sources/
  CLua/                    vendored Lua 5.4.7 C source (see Sources/CLua/VENDOR.md)
  Hammerdeck/
    main.swift             entry point (M1 bridge demo)
    LuaState.swift         the Swift<->Lua bridge -- the seam (Swift side)
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
    rest_timer/            SERVICE feature: idle-aware rest reminders
    window_jump/           ACTION feature: searchable Alt-Tab
test/
  fake_adapter.lua         in-memory adapter (controllable clock)
  run.lua                  headless test suite
docs/
  ARCHITECTURE.md  PLUGIN_SYSTEM.md  HANDOVER.md
  COMPETITIVE_RESEARCH.md  STANDALONE_PRODUCT_IDEA.md
```
