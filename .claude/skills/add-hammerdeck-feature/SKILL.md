---
name: add-hammerdeck-feature
description: Add a new feature to the Hammerdeck platform end-to-end without missing a step. Use when creating a new app/features/<id>/ feature (action or service), wiring its feature.json, Settings options, translations, tests, and gallery preview card. Covers the full checklist (feature.json, capabilities, ctx-only rule, i18n, Package.swift, README regen, tests, gallery card, verification) so the easily-skipped steps are not silently missed.
---

# Adding a Hammerdeck feature

A feature is three co-located parts under `app/features/<id>/`:

```
app/features/<id>/
  feature.json     # DECLARATIVE identity/presentation -- no code
  lua/init.lua     # the plugin: returns the manifest table (id + api + behavior)
  i18n/zh-Hans.json  # translations (every shipped feature has one -- GATED)
  swift/           # OPTIONAL native UI page the feature contributes
```

Features are **autodiscovered** by scanning `app/features/` for a `<id>/lua/init.lua`
-- there is no catalog file to edit. But "it loads" is not "it's done": a feature is
complete only when it has translations, tests, the right trigger/automatable shape,
declared capabilities, and a conscious decision about its gallery preview card.

Read `CLAUDE.md` first if unfamiliar -- the layer map, the one inviolable rule, and
the plugin contract. This skill is the do-not-miss-a-step checklist; that is the why.

## The one rule that governs everything

A feature is **logic only**. It NEVER touches native/OS APIs or the seam. It talks to
the OS exclusively through the scoped `ctx` built in `app/platform/lua/ctx.lua`.

It MAY `require` only the zero-`require` leaf utils -- `platform.json`, `platform.urls`,
`platform.hotkeys`, `platform.windows`, `platform.cyclingChooser` -- plus the one
require-ful exception, the pure factory `platform.favicons` (used as `favicons.new(ctx)`).
It MUST NOT `require` `adapter`, `ctx`, `registry`, `registry_view`, `triggers`,
`manifest`, `modal`, `window_ops`, `window_history`, or anything under `Sources/`.
`test/cases/_integration/platform/feature_requires.lua` fails the build if it does.

If you need an OS capability `ctx` doesn't expose, that is a **seam change**, not a
feature change: add it to `Native+<domain>.swift` + `adapter.lua` + `ctx.lua` first
(a different, larger task -- see CLAUDE.md). Do not reach past the seam.

**Time**: get "now" only from `ctx.now()`. `os.date`/`os.time` are allowed ONLY to
FORMAT or decompose a time you already got from `ctx.now()` -- never to read the wall
clock (tests pin the clock and can't drive it).

**Strings**: never `string.format` over a translated template -- see Step 5.

## Step 1 -- Pick the archetype: ACTION or SERVICE

- **ACTION** = the user fires it (a transform, a generator, a panel). Copy
  `app/features/window_switcher/`, or `app/features/password_generator/` for the
  simplest possible shape.
- **SERVICE** = runs in the background (a watcher, a schedule). Copy
  `app/features/sleep_schedule/`. Declares `start(ctx)` + optional `stop(ctx)`; may
  also declare `actions`.

There is no flat single-file form -- discovery scans for `<id>/lua/init.lua`, so the
directory is mandatory.

## Step 2 -- Write `feature.json` (declarative identity, no code)

This is the file a reader opens to answer "what can this thing do to my machine?"
without reading any Lua. The registry OVERLAYS it onto the Lua manifest at register time.

Every key below is real, but this is a SCHEMA illustration, not a template to copy --
`capabilities` and `page` in particular must reflect what *your* feature actually does
(declaring either one spuriously fails a gate; see Step 3 and Step 8).

```json
{
  "name": "My Feature",
  "version": "1.0.0",
  "description": "One sentence, user-facing -- this is what the Gallery card shows.",
  "category": "productivity",
  "context": "window",
  "icon": "macwindow.on.rectangle",
  "selfEvident": true,
  "requires": ["accessibility"],
  "capabilities": ["network"],
  "page": { "title": "Usage", "icon": "chart.bar.xaxis" }
}
```

Real files to read: `app/features/window_switcher/feature.json` (plain action, no
capabilities), `app/features/usage_stats/feature.json` (capabilities + a `swift/` page).

- **`context`** is a CONTROLLED vocabulary and drives Gallery grouping + Tour order --
  it answers "what must I be doing for this to be useful": `textField` | `window` |
  `web` | `anywhere` | `automatic`. Orthogonal to `category` (the domain tag,
  defaults to `"general"`).
- **`icon`** is an SF Symbol name.
- **`capabilities`** -- see Step 3. Declared HERE, never in `lua/init.lua`.
- **`page`** -- only if the feature contributes a `swift/` page (Step 8).
- Optional booleans validated by `manifest.lua`: `recommended` (first-run one-click
  offer), `preference`, `defaultEnabled`, `selfEvident` (skips the "what did that do?"
  flash on manual fire).

## Step 3 -- Declare capabilities (the gate is checked BOTH ways)

If the feature reaches the network, synthesizes keystrokes, sleeps/locks the machine,
reads the browser, or touches files outside its own `dataDir`, declare the matching
capability. The map is `manifest.CAPABILITY_METHODS` in `app/platform/lua/manifest.lua`
-- **read it there**, don't trust a copy. Today's tiers:

| Capability | Gates (ctx methods) |
|---|---|
| `input` | `keyStroke`, `typeText` |
| `network` | `httpGet`, `httpPost`, `httpRequest`, `downloadFile` |
| `power` | `systemSleep`, `lockScreen`, `displaySleep`, `startScreensaver` |
| `browser` | `browserListTabs`, `browserFocusTab`, `browserActiveURL`, `extractFavicons`, `focusBrowserTab`, `focusSafariTab`, `openSiteApp`, `openSite` |
| `files` | `homeDir`, `fileRead`, `fileWrite`, `fileAppend`, `fileExists`, `mkdir`, `removeSubdir` |
| `commands` | ADDITIVE -- *injects* `ctx.commands()` / `ctx.runCommand()` (the command-palette cross-feature reach). Rare. |

`dataDir()` / `cacheDir()` are ungated -- that's the feature's own sandbox.

**Declare exactly what you use.** `feature_capabilities.lua` fails the build on a
MISSING capability (a latent crash) *and* on an unused one (over-declaring is what rots
the labels into decoration). Requiring `platform.favicons` counts -- it reaches
`ctx.downloadFile` / `ctx.extractFavicons` through the ctx you hand it, so you need
`network` + `browser` (+ `files` if you cache outside dataDir).

Skip this and the feature still loads, then throws a message naming the feature, the
method, the capability and the file to edit -- the first time that path runs.

## Step 4 -- Write the manifest (`lua/init.lua`)

Required: `api = 1` and `id` (unique, snake_case, matches the folder -- it's the anchor).
Plus ONE of: `action(ctx)` + optional `defaultTrigger` (single-action sugar),
`actions = {...}`, or `start(ctx)`.

```lua
actions = {
  { id = "main", label = "Do the thing",
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt", "ctrl" }, key = "d" },
    mnemonic = "D for Do",          -- optional "why this key" hint, shown read-only
    automatable = false,            -- see below; default false
    run = function(ctx) ... end },
}
```

Single-action sugar (`action` + top-level `defaultTrigger` + `mnemonic`) expands to one
action with `id = "main"`. Don't mix `action` with `actions` or `start`.

- **`automatable`** (per action, default `false`). Triggers split into MANUAL (hotkey,
  chord -- a human is present, so live window/selection/clipboard context is meaningful)
  and AUTOMATED (schedule, event -- nobody is there). Set `true` ONLY for a context-free
  state-changer a user might schedule or fire on a system event (bing_daily's "Refresh
  wallpaper now" ships with a schedule as its default trigger). Most actions read the
  live selection and are nonsensical fired unattended -- leave it false. An automated
  `defaultTrigger` REQUIRES `automatable = true`; `manifest.validate` rejects the
  mismatch, the Settings picker hides automated types for a non-automatable action, and
  the registry silently ignores a stale stored one on load.
- **`optionActions`** -- see Step 6.

## Step 5 -- Translations (`i18n/<locale>.json`) -- GATED, not optional

Every shipped feature has one. Localize through `ctx` and **let it do the formatting**:

```lua
ctx.t("copied", "Copied %1$s to %2$s", what, where)
ctx.plural("chooser.count", n, { one = "%d window", other = "%d windows" }, n)
```

`ctx.plural(key, count, forms, ...)` -- `forms` is a `{ one =, other = }` table of
inline English templates, and the format arguments come AFTER it (so `count` is
typically passed twice: once to select the form, once to fill the slot).

NEVER `string.format` over a translated template. Only the i18n layer honors positional
specifiers (Lua's own `string.format` cannot reorder arguments and RAISES on `%2$s`) and
only it refuses to throw when a translation's slots don't match -- so a raw format turns
one mistyped placeholder in a catalog into a crash inside a firing rule.

**A template with 2+ slots MUST number them** (`%1$s` / `%2$s`) in the English source
AND the translation. Plain `%s` makes argument order load-bearing, and no author knows
which language needs a different one (Chinese wants "把 <display> 的壁纸设为 <color>").
One slot needs no number.

Catalog keys, as built by `registry_view.lua` (see any
`app/features/*/i18n/zh-Hans.json`): `name`, `description`,
`action.<actionId>.{label,description,mnemonic}`,
`option.<key>.{label,hint,section,defaultLabel,actionLabel}`,
`option.<key>.values.<value>` for enum labels, plus every `ctx.t` / `ctx.plural` key
your code asks for.

Both rules are gated -- `i18n_parity.lua` diffs a real `describe()` under `en` vs
`zh-Hans` and resolves every literal `ctx.t` key in the source, so an untranslated
string fails the build rather than quietly speaking English at a Chinese user. Write
each `ctx.t` default as a **plain string literal** -- a concatenation or a variable
doesn't match the scanner's pattern and ships unchecked.

## Step 6 -- Options (the Settings form is GENERATED, never hand-coded)

Declare `options = { ... }`; the SwiftUI form is generated from them. Valid `type`
values: `bool`, `int` (with `min`/`max`), `string` (with `multiline`, `collapsible`),
`enum` (with `values` + parallel `labels`), `time`, `appList`, `siteList`,
`placementList`, `secret`. Read live values with `ctx.opt(key)` (and `ctx.secret(key)`
for secrets) -- never cache them.

- **enum**: `values = {...}`, `labels = {...}` -- `manifest.lua` enforces that `labels`
  is the same length as `values`, but NOT that `default` is one of them; keep it in the
  set yourself, since nothing will tell you. Store the value the code uses directly (the
  actual pattern), with a human label.
- **`hint`** -- one-line help under the control. **`section`** -- groups controls.
- **Validate / preview button**: declare `actionLabel = "Test"` (or "Preview") on an
  option AND add `optionActions = { <optKey> = function(ctx) ... end }`. The form renders
  a button that runs the handler with the live ctx; tests fire it via
  `registry.runOptionAction("<id>", "<optKey>")`. Use it to VALIDATE free-form input --
  see `insert_datetime` (Preview) and `text_actions` (dictApp Test).
- **`secret` + `validate = "<provider>"`**: a login-Keychain credential with a
  host-checked "Validate" button (a secret may NOT carry a `default`). Gate dependent
  options with `gatedBy`, and feed an enum from it with `valuesFrom`. See `text_actions`
  (openaiKey/model).
- **Defensive formatting**: if you call something that can RAISE on bad option input
  (`os.date` raises on an invalid strftime specifier in Lua 5.4), `pcall`-guard it and
  notify -- don't let a bad option crash an action.

## Step 7 -- Tests: a NEW CASE FILE, not an edit to `test/run.lua`

`test/run.lua` is a **pure runner** -- it discovers cases and runs each in a fresh
world, and holds no test bodies. Do not add one there. Write `test/cases/<id>.lua`, hermetic,
returning `{ id, run = function(t) ... end, tags? }`:

```lua
return {
    id = "<id>",
    ---@param t Harness
    run = function(t)
        local ok, fake, registry = t.ok, t.fake, t.registry

        registry.register(require("features.<id>"))
        fake.settings["hammerdeck.opt.<id>.<key>"] = <value>
        registry.setEnabled("<id>", true)

        fake.pressHotkey("d")                    -- fire the default hotkey
        ok(<assertion about fake side-effects>, "describe it")
        -- ... cover edge cases: empty/invalid option, boundary values ...

        registry.setEnabled("<id>", false)
    end,
}
```

The case registers its own feature (the harness does not disk-discover), and the runner
asserts a clean handle count after every case -- that tripwire catches leaked
watchers/timers, the #1 service bug, so you don't assert it yourself. `freshWorld()`
gives each case a pristine registry + catalog, so cases are order-independent; keep
yours that way (`lua test/run.lua --shuffle` proves it).

The fake adapter (`test/fake_adapter.lua`) records side-effects: `fake.settings`,
`fake.notifications`, `fake.alerts`, `fake.pasteboard`, `fake.typedTexts`,
`fake.keyEvents`, `fake.timers`, `fake.hotkeys`, `fake.chords`, `fake.watchers`,
`fake.choosers`, `fake.banners`, `fake.huds`, `fake.windows`, `fake.focused`,
`fake.openedUrls`, `fake.actions`, and drives time via `fake.clockOffset`.
Run one case with `lua test/run.lua <id>`.

A real feature's `feature.json` is read from disk via io, so its metadata merges in
tests too -- which is how the capability and i18n guards see your new feature for free.

## Step 8 -- Wire the build (both are CI-gated)

1. **`Package.swift`**, `HammerdeckKit` target -- SwiftPM scans the whole `app/` subtree
   for resources, so an unlisted feature reproduces the "N unhandled files" warning
   (harmless; the feature still loads):
   - Lua-only feature -> add `"features/<id>"` to `exclude`.
   - Feature WITH a `swift/` -> add `"features/<id>/swift"` to `sources` AND all three
     of `"features/<id>/lua"`, `"features/<id>/i18n"`, `"features/<id>/feature.json"`
     to `exclude`. (`exclude` overrides `sources`, so a broad `exclude: ["features"]`
     would drop the swift too -- list each. Omitting the `i18n` entry leaves exactly
     the warning this step is meant to silence; compare the `usage_stats` /
     `window_deck` / `window_fan` entries already in the file.)
2. **`scripts/gen-readme-features.py`** -- README's feature catalog is GENERATED from
   every `feature.json`, and **CI fails if it is stale**. Run it after adding the
   feature. (The list used to be hand-written and rotted badly, never once naming
   window_deck.)

A `swift/` page additionally needs registering in
`app/platform/swift/FeaturePageRegistry.swift` plus the `page` block in feature.json.
Worked examples: `usage_stats`, `window_deck`, `window_fan`.

## Step 9 -- Gallery preview card (DON'T silently skip -- decide consciously)

A feature's visual card in the Settings Feature Gallery comes from
`FeatureArchetype.of(_:)` in `app/platform/swift/FeatureArchetypeAnimation.swift` -- a
switch on feature `id`. A feature NOT listed there falls to `.none`: it still works, but
shows only a static icon, looking unfinished next to its peers. **This is the step most
easily missed.** Choose one:

1. **Reuse an existing archetype** -- map your `id` to the closest case. Archetypes
   preview the visible EFFECT, not the trigger: `.chooser` (a panel pops),
   `.windowArrange` (a rect moves), `.windowGrid`, `.windowDeck`, `.windowFan`,
   `.windowRewind`, `.banner`, `.screenOff`, `.countdownStrip`, `.pointerPulse`,
   `.pointerFollow`, `.passwordReveal`, `.chart`, `.wallpaperSwap`, `.textTransform`,
   `.typeText(String)`. Add a `loopDuration` arm and a `scene(...)` arm if the case
   carries new content; keep `loopDuration` = the scene's heartbeat interval × cycle
   length (the playback bar relies on it).
2. **Add a new archetype** -- only if no existing effect fits. Add the enum `case`, a
   `loopDuration`, a `scene(...)` arm, and a `FeatureArchetypeScene+*` view. Prefer
   parameterizing an existing scene (as `.typeText` reuses `TypeKeystrokesArchetypeScene`).
3. **Deliberately exempt** -- if the feature genuinely has no visual moment. This is
   NOT a bare `.none`: `testEveryGalleryFeatureHasAPreview` in
   `Tests/HammerdeckTests/IntegrationTests.swift` reads the live catalog and fails on
   any non-exempt feature that falls to `.none`. You must ALSO add the id to that
   test's `previewExempt` set **with a reason**. The set is empty today, on purpose --
   every shipped feature earns a preview, so treat this as the rare exception it is.

Per-option toggle preview cards (`preview = "token"` on an option, rendered by
`FeatureArchetypeScene+OptionPreview.swift`) are a SEPARATE, bespoke mechanism used only
by `text_actions`. Most features don't need them.

No Swift change is needed for a feature merely to APPEAR -- the catalog is read from Lua
via `registry.describe()`.

## Step 10 -- Verify

```bash
luac -p app/features/<id>/lua/init.lua   # syntax (or app/**/*.lua)
lua test/run.lua                         # fast loop (Homebrew Lua 5.5)
scripts/test-lua.sh                      # SAME suite on vendored 5.4.7 -- before committing
scripts/gen-readme-features.py           # regenerate the README catalog (CI gate)
swift build                              # must be clean
scripts/test-swift.sh                    # REQUIRED for every new feature -- see below
```

**`scripts/test-swift.sh` is not optional for a new feature**, even when you touched no
Swift. CI runs bare `swift test` on every push, and two of its integration tests read the
live on-disk catalog, so a pure-Lua feature can turn them red:
`testEveryGalleryFeatureHasAPreview` (Step 9 -- the step most easily missed, and the one
these tests exist to catch) and `testFeaturePageRosterMatchesDeclarations` (a `page` in
feature.json with no `FeaturePageRegistry` provider, or the reverse). Use the wrapper
rather than piping `swift test` into a filter -- a pipeline reports the LAST command's
status, so a hard failure reads as success and the failing case's name is discarded.

Keep all Lua **5.4-compatible** -- the embedded engine is 5.4.7 even though the dev
machine's `lua` may be 5.5; `scripts/test-lua.sh` closes that gap. Annotate cross-file
functions and non-obvious table shapes with LuaLS `---@` annotations
(`app/platform/lua/json.lua` is the worked example); any table crossing the Swift bridge
or `json.encode` that could be empty or array-vs-object must carry `__jsontype` via
`json.asObject` / `json.asArray`. `scripts/check-lua-types.sh` enforces this at Error
level in CI.

**Then restart the app for the user and STOP** -- `./scripts/restart.sh` rebuilds and
relaunches, then the user verifies the behavior live before anything is committed.

Real-pixel check of the generated Settings form (no Screen Recording needed, captures
the full scroll height):

```bash
scripts/control.sh '@settings:<id>'      # open Settings to this feature's detail
scripts/control.sh '@shot:/tmp/out.png'  # the app renders its own form to a PNG
```

Use `scripts/shot.sh` only for native panels (chooser/banner), which live outside the
Settings window.

## Step 11 -- Loose ends

- A feature MUST keep PERMANENT, terse `ctx.log` traces of its meaningful runtime
  DECISIONS and state transitions -- enable/disable, and each branch a stateful loop
  takes (window_deck logs on/off, promote, drop, peek-stay, suppressed settling-echo).
  These are the audit trail that makes a live bug diagnosable from the log alone. Do NOT
  strip them as "debug noise" once the fix lands.
- Don't auto-commit; exclude `TODO.md`. Wait for an explicit commit signal.
- Don't add the feature to a "catalog" file. Discovery is `registry.loadFromDir` over
  `app/features/`. (`app/hammerdeck.lua` does hold a hand-maintained
  `registry.loadCatalog({...})` list, but it is a fallback for the case where the
  script's own path can't be resolved -- not a registry to keep current.) The only
  hardcoded-by-id Swift touchpoints are the gallery archetype (Step 9) and the OPTIONAL
  page registration (Step 8).

## Quick checklist

- [ ] `app/features/<id>/feature.json` -- name, version, description, category,
      `context` (controlled vocab), icon, `capabilities`
- [ ] `app/features/<id>/lua/init.lua` -- manifest, `api = 1`, unique `id` matching folder
- [ ] ACTION (`action`/`actions` + trigger) or SERVICE (`start`/`stop`)
- [ ] `ctx`-only; leaf-util requires only; time via `ctx.now()`
- [ ] `automatable` set correctly (false unless context-free state-changer)
- [ ] capabilities declared EXACTLY (guard fails on missing AND unused)
- [ ] `i18n/zh-Hans.json` complete; all user strings via `ctx.t`/`ctx.plural`;
      2+ slots numbered `%1$s`; `ctx.t` defaults are plain literals
- [ ] options declared; live reads via `ctx.opt`; free-form input validated
      (`optionActions` + `actionLabel`) and raise-guarded
- [ ] LuaLS `---@` annotations on cross-file shapes; `__jsontype` if it crosses the bridge
- [ ] `test/cases/<id>.lua` -- hermetic, order-independent, covers edge cases
- [ ] `Package.swift` `exclude`/`sources` updated; `gen-readme-features.py` re-run
- [ ] gallery archetype mapped in `FeatureArchetypeAnimation.swift` (or exempted in
      `previewExempt` WITH a reason -- a bare `.none` fails CI)
- [ ] permanent `ctx.log` decision traces in place
- [ ] `lua test/run.lua` + `scripts/test-lua.sh` green; `swift build` clean
- [ ] `scripts/test-swift.sh` green -- REQUIRED even for a pure-Lua feature
- [ ] `./scripts/restart.sh` run, user verified live
