---
name: add-hammerdeck-feature
description: Add a new feature to the Hammerdeck platform end-to-end without missing a step. Use when creating a new lua/features/* feature (action or service), porting a Hammerspoon module/spoon into Hammerdeck, or wiring its Settings options, tests, and gallery preview. Covers the full checklist (manifest, ctx-only rule, tests, Swift gallery card, verification) so steps like the gallery preview are not silently skipped.
---

# Adding a Hammerdeck feature

A feature is a self-describing Lua table (a manifest) under `lua/features/`,
receiving only the scoped `ctx`. It is **autodiscovered** — dropping the folder
in is enough for it to appear in Settings/menubar. But "it loads" is not "it's
done": a feature is only complete when it has tests, the right trigger/automatable
shape, and (a conscious decision about) a gallery preview card.

Read `CLAUDE.md` (layer map + the one inviolable rule) and `docs/PLUGIN_SYSTEM.md`
(contract rationale) first if unfamiliar. This skill is the do-not-miss-a-step
checklist; those are the why.

## The one rule that governs everything

A feature is **logic only**. It NEVER touches native/OS APIs or the seam. It
talks to the OS exclusively through `ctx` (the curated plugin API built in
`lua/platform/ctx.lua`). It MAY `require` only the pure leaf utils
(`platform.json`, `platform.urls`, `platform.hotkeys`, `platform.windows`).
It MUST NOT `require` `adapter`, `registry`, `triggers`, `manifest`, `modal`,
or anything under `Sources/`.

If you need an OS capability `ctx` doesn't expose, that is a **seam change**, not
a feature change: add it to `Native+<domain>.swift` + `adapter.lua` + `ctx.lua`
first (a different, larger task — see CLAUDE.md). Do not reach past the seam.

Time: get "now" only from `ctx.now()`. `os.date`/`os.time` are allowed ONLY to
FORMAT or decompose a time you already got from `ctx.now()` — never to read the
wall clock (tests can't drive it).

## Step 1 — Pick the archetype: ACTION or SERVICE

- **ACTION** = user fires it (a transform, a generator, a panel). Copy
  `lua/features/window_switcher/` or, simplest, `lua/features/password_generator/`.
- **SERVICE** = runs in the background (a watcher, a schedule). Copy
  `lua/features/sleep_schedule/`. Declares `start(ctx)` + optional `stop`; may
  also declare `actions`.

Trivial features can be a flat `lua/features/<name>.lua` returning the manifest;
anything with assets or growth uses a directory with `init.lua`.

## Step 2 — Write the manifest

Required: `api = 1`, `id` (unique, snake_case, matches the folder), `name`.
Plus ONE of: `action(ctx)` + optional `defaultTrigger` (single-action sugar),
`actions = {...}`, or `start(ctx)`.

Action list shape — one feature, several independently rebindable shortcuts:

```lua
actions = {
  { id = "main", label = "Do the thing",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "d" },
    mnemonic = "D for Do",          -- optional "why this key" hint, shown read-only
    automatable = false,            -- see below; default false
    run = function(ctx) ... end },
}
```

Single-action sugar (`action` + top-level `defaultTrigger` + `mnemonic`) expands
to one action with `id = "main"`. Don't mix `action` with `actions` or `start`.

Key fields and their gotchas:

- **`automatable`** (per action, default `false`). Set `true` ONLY for a
  context-free state-changer a user might schedule or fire on a system event
  (refresh wallpaper, toggle a setting, lock screen). Most actions read the live
  selection/window/clipboard and are nonsensical fired unattended — leave it
  false. A `schedule`/`event` `defaultTrigger` REQUIRES `automatable = true`
  (manifest.validate rejects the mismatch).
- **`category`** — defaults to `"general"`; set `"productivity"` etc.
- **`capabilities = {"commands"}`** — only if the feature needs privileged
  cross-feature reach (`ctx.commands()` / `ctx.runCommand()`, the palette). Rare.
- **`mnemonic`** — pure metadata; UI hides it once the user rebinds.

## Step 3 — Options (the Settings form is GENERATED, never hand-coded)

Declare `options = { ... }`; the SwiftUI form is generated from them. Valid
`type` values: `bool`, `int` (with `min`/`max`), `string` (with `multiline`,
`collapsible`), `enum` (with `values` + parallel `labels`), `time`, `appList`,
`secret`. Read live values with `ctx.opt(key)` (and `ctx.secret(key)` for
secrets) — never cache them.

Useful extras:

- **enum**: `values = {...}`, `labels = {...}` (same length); `default` MUST be
  one of `values`. Store the value the code uses directly (e.g. the actual
  pattern), with a human label.
- **`hint`** — one-line help under the control.
- **`section`** — groups controls into form sections.
- **Validate / preview button**: declare `actionLabel = "Test"` (or "Preview")
  on an option AND add `optionActions = { <optKey> = function(ctx) ... end }`.
  The form renders a button that runs the handler with the live ctx. Use this to
  VALIDATE free-form input (e.g. a custom format / a dictionary app) — see
  `insert_datetime` (Preview) and `text_actions` (dictApp Test).
- **`secret` + `validate = "<provider>"`**: a Keychain-backed credential with a
  host-checked "Validate" button; gate dependent options with `gatedBy`, and
  feed an enum from it with `valuesFrom`. See `text_actions` (openaiKey/model).
- **Defensive formatting**: if you call a function that can RAISE on bad option
  input (e.g. `os.date` raises on an invalid strftime specifier in Lua 5.4),
  `pcall`-guard it and notify — don't let a bad option crash an action.

## Step 4 — Type-friendliness

Annotate cross-file functions and non-obvious table shapes with LuaLS `---@`
annotations (`platform/json.lua` is the worked example). Any table that crosses
the Swift bridge or `json.encode` and could be empty/array-vs-object must carry
the `__jsontype` tag via `json.asObject`/`asArray`.

## Step 5 — Tests (REQUIRED — a feature without a test is not done)

The harness in `test/run.lua` uses its OWN catalog (not disk discovery), so you
must register the feature there explicitly and cover its main flow. Pattern
(see the `password_generator` / `plain_paste` / `insert_datetime` blocks):

```lua
registry.register(require("features.<id>"))
registry.setEnabled("<id>", true)
fake.settings["hammerdeck.opt.<id>.<key>"] = <value>
fake.pressHotkey("d")                       -- fire the default hotkey
ok(<assertion about fake side-effects>, "describe it")
-- ... cover edge cases (empty/invalid option, etc.) ...
registry.setEnabled("<id>", false)
ok(registry.liveHandleCount() == 0 and fake.liveHandles == 0, "clean after <id> test")
```

The fake adapter (`test/fake_adapter.lua`) records side-effects: `fake.typedTexts`,
`fake.pasteboard`, `fake.alerts`, `fake.notifications`, `fake.keyEvents`,
`fake.openedUrls`, etc., and drives time via `fake.clockOffset` / `fake.now()`.
Fire an option-action (Test/Preview button) with
`registry.runOptionAction("<id>", "<optKey>")`. ALWAYS end with the
clean-handle assertion — it catches leaked watchers/timers (the #1 service bug).

## Step 6 — Gallery preview card (DON'T silently skip — decide consciously)

A feature's visual card in the Settings Feature Gallery comes from
`FeatureArchetype.of(feature)` in
`Sources/HammerdeckKit/FeatureArchetypeAnimation.swift` — a switch on feature
`id`. A feature NOT listed there falls to `.none`: it still works, but shows
only a static icon, looking unfinished next to its peers. **This is the step
most easily missed.** For each new feature, consciously choose:

1. **Reuse an existing archetype** — map your `id` to the closest case in
   `of(_:)`. Archetypes preview the visible EFFECT, not the trigger:
   `.chooser` (a panel pops), `.windowArrange` (a rect moves), `.banner`,
   `.screenOff`, `.textTransform`, `.typeText(String)` (keystrokes typed out),
   `.wallpaperSwap`, `.chart`, etc. Add a `loopDuration` arm and a `scene(...)`
   arm if the case carries new content; keep `loopDuration` = the scene's
   heartbeat interval × cycle length (the playback bar relies on it).
2. **Add a new archetype** — only if no existing effect fits. Add the enum
   `case`, a `loopDuration`, a `scene(...)` arm, and a `FeatureArchetypeScene+*`
   view. Prefer parameterizing an existing scene (as `.typeText` reuses
   `TypeKeystrokesArchetypeScene` with overridable `full`/`caption`).
3. **Deliberately `.none`** — if the feature genuinely has no visual moment
   (e.g. it only copies to the clipboard with no on-screen effect). Fine, but
   make it a decision, not an omission.

Per-option toggle preview cards (`preview = "token"` on an option, rendered by
`FeatureArchetypeScene+OptionPreview.swift`) are a SEPARATE, bespoke mechanism
used only by `text_actions`' show/hide toggles. Most features don't need them;
add one only if a toggle row genuinely warrants an animated mini-card (requires
a new Swift view per token).

Any Swift edit means a `swift build` (Step 7). No Swift change is needed for a
feature merely to APPEAR — the catalog is read from Lua via `registry.describe()`.

## Step 7 — Verify (all of these)

```bash
luac -p lua/features/<id>/init.lua    # or **/*.lua — syntax
lua test/run.lua                      # fast loop (Homebrew Lua 5.5)
scripts/test-lua.sh                   # SAME suite on vendored 5.4.7 (the real engine) — run before committing
swift build                           # ONLY if you touched Swift (gallery/options) — must be clean
```

Keep all Lua **5.4-compatible** (the embedded engine is 5.4.7 even though the
dev machine's `lua` may be 5.5; `scripts/test-lua.sh` closes that gap).

Real-pixel check when UI matters (you must be at the machine; ask first — don't
restart the user's instance or run UI tests while they're at the keyboard):

```bash
scripts/app.sh start
scripts/control.sh '@settings:<id>'   # open Settings to this feature's detail
scripts/shot.sh out.png               # screenshot the form / gallery card
```

The capturing terminal needs Screen Recording or panels are missing from the
image. `swift test` is only needed if you changed the seam (you shouldn't have).

## Step 8 — Loose ends

- If porting from the donor Hammerspoon config: remove the old binding from its `init.lua` (a
  duplicate global hotkey in both apps clashes — whichever registers first wins,
  the other fails silently) and move the dead module to `retired/`, with a dated
  head-comment note.
- Don't auto-commit; exclude `TODO.md`. Wait for an explicit commit signal.
- Don't add the feature to any "catalog" file — there isn't one; discovery is by
  directory scan. The only hardcoded-by-id Swift touchpoint is the OPTIONAL
  gallery archetype in Step 6.

## Quick checklist

- [ ] `lua/features/<id>/init.lua` — manifest, `api = 1`, unique `id`, `name`
- [ ] ACTION (`action`/`actions` + trigger) or SERVICE (`start`/`stop`)
- [ ] `ctx`-only; no native/seam/stateful-platform requires; time via `ctx.now()`
- [ ] `automatable` set correctly (false unless context-free state-changer)
- [ ] options declared; live reads via `ctx.opt`; free-form input validated
      (`optionActions` + `actionLabel`) and raise-guarded
- [ ] LuaLS `---@` annotations on cross-file shapes; `__jsontype` if it crosses the bridge
- [ ] test in `test/run.lua` incl. edge cases + clean-handle assertion
- [ ] gallery archetype mapped in `FeatureArchetypeAnimation.swift` (or `.none` by decision)
- [ ] `lua test/run.lua` + `scripts/test-lua.sh` green; `swift build` clean if Swift touched
- [ ] old binding removed + module retired (if porting)
