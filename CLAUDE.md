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
the class, shared state and `installBindings`; the actual OS calls live in the
`Native+<domain>.swift` extensions of the same type (`ls
app/platform/swift/Native+*.swift` for the current set -- an enumerated list here
went stale twice, so the invariant is "one slice per domain", not a snapshot).
New OS surface grows in whichever `Native+*` slice fits
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

> Current state: **no Hammerspoon** -- dropped as a backend by owner decision.
> **Co-located layout**: everything
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
> prompts for the Accessibility grant when missing).

## Layers (top depends on bottom only)

`app/features/*/lua` -> `registry` -> `triggers` / `manifest` -> `adapter` (Lua seam)
-> `LuaState.swift` (Swift bridge) -> macOS APIs

**`app/platform/lua/` tiers** (the dir is FLAT; this is the layering `ls` does
not show): **SEAM** = `adapter.lua` (the only file here that reaches `native.*`).
**CORE / stateful** = `ctx`, `registry`, `registry_view`, `triggers`, `manifest`,
`modal`, `window_ops`, `window_history` (hold state + lifecycle; features never
`require` them). `registry_view` is the registry's read model -- stateless
itself, but registry-injected and firmly off the feature allowlist. `window_ops` owns the live focused-window move +
"pointer-follows-window" policy (`ctx.window.setFrame` delegates to it); the
registry injects its pointer-follow predicate at boot. It ALSO owns the
EXCLUSIVE WINDOW-MODE LEASE: one mode per screen, because Window Deck and
Window Fan each capture a member's current frame as the frame to restore, so a
second mode over the first records the FIRST one's arrangement as the "original
layout" and the user's real one is then unrecoverable. It lives here for the
same reason pointer-follow does -- a policy spanning features has to sit where
no feature can require another. Features reach it only through
`ctx.window.requestExclusive`, which arbitrates, asks the user, evicts, waits
for the restore to land, and claims, all in ONE call: splitting grant from
claim is what leaves the slot readable as empty, and a second mode let in there
re-creates the exact bug. Every window MOVER consults it too (window_snap,
window_grid, window_modal, window_rewind), passing `W.focusedScreen(ctx)` --
NOT `ctx.window.frame().screen`, which is a bare `{x,y,w,h}` with no index to
key a lease by and no pointer fallback. A guard case fails a new FEATURE that
moves a window without consulting it; it is a per-file scan, so it does not
catch a new unGATED ACTION inside a feature that already consults it elsewhere. `window_history` is the
single-step window-undo engine behind `ctx.window.undoLast` (only `window_ops`
requires it). **SUBSYSTEM** = the automation rules engine
(`rules` + `signals` + `effects` -- domain logic that, like core, requires the
adapter's high-level surface but never touches `native.*` directly -- only
`adapter.lua` does that), plus `i18n` (locale-injected, internal), `text`
(a tiny pure string helper for rules/effects; zero-require but NOT on the
feature allowlist) and `capscan` (the capability-DECLARATION rule: text in,
verdict out, touching no adapter or filesystem -- shared by the build guard
`feature_capabilities.lua` and the runtime `registry.validateExtension` so the
two cannot answer the same question differently; the callers differ only in how
they enumerate source. It scans `ctx%.` calls AND `capscan.RAW_REACH`, the
stdlib calls that reach the OS around ctx).
`favicons` sits in this tier structurally but is a **pure factory subsystem** a
feature MAY `require` (it needs only the `urls` leaf util, used as
`favicons.new(ctx)`) -- a sibling to the leaf utils, NOT a zero-`require` leaf
itself (so it stays OFF the leaf-guard list). **LEAF UTILS** =
`json`, `urls`, `hotkeys`, `windows`, `cyclingChooser` (the invariant is ZERO
`require`, NOT purity -- they may call native, but only via a `ctx` passed in, e.g.
`windows.focusedOrAlert`; the only ZERO-`require` platform modules a feature may
`require` -- `favicons` above is the one require-ful module also allowed; a
test-suite guard fails if any of them grows a `require`, and the mirror guard
(`test/cases/_integration/platform/feature_requires.lua`) fails if a feature
requires anything outside this allowlist -- which lives in ONE place,
`manifest.FEATURE_REQUIRABLE`, because `registry.validateExtension`'s require
walk keys off the same set and a second copy would eventually disagree with the
one the running app enforces). The `ctx` surface is
namespaced into domain sub-tables (`ctx.window.*` / `ctx.screen.*` /
`ctx.mouse.*`), and Hammerspoon's pure-Lua tiling/grid algorithms are ported
onto `platform.windows`, which the `window_*` features ride.

- **app/features/<id>/** -- one feature, three co-located parts: `feature.json`
  (DECLARATIVE identity/presentation -- name, version, description, category,
  context, `capabilities` (see CAPABILITIES below), and optional
  requires/recommended/page; no code), `lua/` (the plugin
  code: `init.lua` returns the manifest table -- `id` (the anchor) + `api` +
  behavior), and an optional `swift/` (native UI the feature contributes, e.g.
  usage_stats' report page). The registry OVERLAYS feature.json onto the manifest
  at register time. The `lua/init.lua` declares (`api = 1`; ACTIONS =
  `actions = {{id, label, defaultTrigger?, automatable?, run}, ...}` -- one plugin,
  several independently rebindable shortcuts; single-action sugar
  `defaultTrigger`+`action(ctx)` still works; SERVICE = `start(ctx)`+optional
  `stop`, may also declare `actions`), and receives the scoped `ctx` as its native
  surface. Never touches native APIs or the seam/stateful platform modules
  (`adapter`, `ctx`, `registry`, `triggers`, `manifest`, `modal`, `window_ops`,
  `window_history`);
  MAY `require` the pure leaf util modules (`platform.json`, `platform.urls`,
  `platform.hotkeys`, `platform.windows`, `platform.cyclingChooser` -- stateless,
  no `require` of their own), PLUS the pure factory subsystem `platform.favicons`
  -- a sibling category to the leaf utils (it requires only the `urls` leaf util
  and is used via `favicons.new(ctx)`), NOT itself a zero-`require` leaf util, so
  it must NOT join the leaf-guard list. **Localize through `ctx`, and let it do the
  formatting**: `ctx.t(key, "English %1$s source", a, b)` / `ctx.plural(...)` --
  NEVER `string.format` over a translated template. Only the i18n layer honors a
  locale's positional specifiers (Lua's own `string.format` cannot reorder
  arguments and RAISES on `%2$s`) and only it refuses to throw when a translation's
  slots don't match, so a raw format turns one mistyped placeholder in a catalog
  into a crash inside a firing rule. A template with **2+ slots must number them**
  (`%1$s` / `%2$s`) in the English source AND the translation -- plain `%s` makes
  argument order load-bearing, and no author knows which language needs a different
  one (Chinese wants "把 <display> 的壁纸设为 <color>"). One slot needs no number.
  Both rules are GATED (i18n_parity.lua + LocalizationTests), so a new feature that
  breaks them fails the build. Get the current time only from
  `ctx.now()` (never bare `os.time()`/`os.date()`, which read the uncontrolled
  wall clock and tests can't drive); `os.date`/`os.time` are fine for FORMATTING
  or decomposing a time you already got from `ctx.now()`. (Exception: a
  feature-contributed *host reporter* -- see "The one inviolable rule" -- runs
  outside `ctx`, so it has no `ctx.now()` and reads the wall clock directly.)
- **app/loader.lua** -- installs the `package.searcher` that maps the stable
  `platform.*` / `features.<id>.*` require names onto their `lua/` subfolders, so
  the co-located layout needs zero require rewrites. Exposes `appdir` (the
  registry uses it to locate `<id>/feature.json`). The `swift/` sibling is
  invisible to `require`. A third namespace, `extensions.<id>.*`, maps onto the
  USER-EXTENSIONS folder (see the registry bullet); it is detached (defers to
  the other searchers) until `setExtensionsRoot` points it somewhere.
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
  LIFECYCLE ONLY: it decides what IS. Also loads **USER EXTENSIONS**
  (`registry.loadExtensions`, called at boot and inside `reload()`): Lua-only
  features the user keeps in their own folder (the `hammerdeck.extensionsDir`
  setting, picked in Settings > General), laid out exactly like a built-in
  (`<folder>/<id>/lua/init.lua` + optional feature.json + i18n/) and required via
  the `extensions.<id>` namespace. Same manifest contract, same ctx, same
  RUNTIME capability gate; quarantined like the catalog; `describe()` flags each
  with `extension = true` (the Settings badge). The BUILD-time guard suites
  (feature_requires / feature_capabilities / i18n_parity / gallery preview)
  deliberately cover only the first-party catalog -- an extension is the user's
  own code, gated at runtime but not by our CI. `registry.validateExtension(id)`
  is what an extension author gets instead: it walks the REQUIRE GRAPH from the
  extension's `init.lua` (siblings, plus the platform modules it pulls in, whose
  gated calls run through the feature's own ctx) and compares the reach against
  the declared `capabilities` in BOTH directions. Exposed as the
  `validate_extension` MCP tool -- `reload` proves an extension loads, this
  proves it declared itself honestly.
- **app/platform/lua/registry_view.lua** -- the registry's READ MODEL: localized
  names/labels, `describe()` (the whole config-UI payload), the command list, the
  Hyper legend, the trigger summary. It only DESCRIBES what registry decided;
  nothing here mutates. Dependency direction is registry -> view, never back --
  the view needs live state, so registry injects the accessors via
  `view.configure` at load (the same composition-root idiom `window_ops` uses for
  its pointer-follow predicate). Reach it through `registry.describe()` /
  `registry.hyperLegend()`: callers keep one entry point and need not know about
  the split.
- **app/platform/lua/ctx.lua** -- builds the scoped, curated ctx (the plugin API);
  every handle a feature creates is tracked and stopped on disable. It also
  applies the **CAPABILITY GATE** (see below), which is the last thing it does.
- **CAPABILITIES** -- a feature declares what it may reach in its `feature.json`
  (`"capabilities": ["network", ...]`), NOT in `lua/init.lua`; feature.json is the
  declarative file a reader opens to answer "what can this thing do to my
  machine?" without reading the code. The tiers and the exact ctx methods each
  one gates live in ONE place, `manifest.CAPABILITY_METHODS` -- read it there
  rather than trusting a list here, which would go stale. Two shapes: GATED
  (the method exists on ctx and is withheld unless declared -- network, input
  synthesis, power, browser reads, out-of-dataDir file IO) and ADDITIVE
  (`commands` INJECTS `ctx.commands()` / `ctx.runCommand()`, the cross-feature
  reach behind the command palette, which no ordinary feature gets).
  A withheld method is replaced by a **raising stub**, never deleted, so the
  failure names the feature, the method, the capability and the file to edit --
  not `attempt to call a nil value`. Note the reach is TRANSITIVE: `platform.
  favicons` calls `ctx.downloadFile` / `ctx.extractFavicons` through the ctx it
  is handed, so a feature using it needs `network` + `browser` + `files` too.
  This is **auditability, not a sandbox** -- the catalog is first-party and a
  feature could simply declare everything; the value is that the claim is
  greppable and machine-checked. `test/cases/_integration/platform/
  feature_capabilities.lua` checks declarations against real usage in BOTH
  directions: under-declaring is a latent crash, and over-declaring is what rots
  the labels into decoration, so a capability nothing uses fails the build too.
  **`exec` (`ctx.run`) is for USER EXTENSIONS only** -- the same guard fails a
  first-party feature that declares or reaches it. A child process can do
  anything the user can, so `exec` is effectively every tier at once; a catalog
  feature that needs OS surface grows it in the seam, where the call is one
  reviewed named thing. What it canNOT do is borrow Hammerdeck's macOS privacy
  grants: `run_process` launches every command (`ctx.run` and the runCommand
  rule effect alike) through the `DisclaimedExec` trampoline, which makes it its
  own responsible process and fails closed -- anything that can write
  Hammerdeck's settings could otherwise plant a command that inherits Full Disk
  Access. It does not cover code that runs INSIDE Hammerdeck: an extension's
  `files` reads use Hammerdeck's grants, and writing `hammerdeck.extensionsDir`
  alone gets one loaded -- its top-level code runs at load, enabled or not. Only
  protecting the settings that grant code would close that; it is deliberately
  not built. Two consequences of the tier existing at all: the
  embedded state replaces `os.execute` / `io.popen` with raising stubs naming
  `ctx.run` (`LuaState.installSubprocessStubs`); and `capscan.RAW_REACH` covers
  the stdlib calls that reach the OS around ctx, in **two kinds** whose verdicts
  differ -- `cap` (works, so declare it: `io.open` -> `files`) and `use`
  (WITHDRAWN, so declaring is useless and only the rewrite helps), the second
  failing `validateExtension` on its own. That split is the point: counting a
  declaration for a raising stub would report an extension as honest AND
  unrunnable. `load()` and `package.loadlib` still defeat any static scan, and
  nothing here claims otherwise.
- **app/platform/lua/adapter.lua** -- the seam (Lua side); every binding it returns
  is a handle with `.stop()`.
- **app/platform/swift/LuaState.swift** -- the bridge mechanics: owns the
  Lua state, runs Lua, callback refs, table readers, `eval`.
- **app/platform/swift/Native.swift + Native+*.swift** (+ HotkeyCenter/ChordCenter
  and per-panel UI files) -- the seam (Swift side): the `native` table the adapter
  calls. `Native.swift` is the class + shared state + `installBindings`; the OS
  calls are grouped into `Native+<domain>.swift` extensions. The only place
  macOS-API surface should grow.
  **Anything that blocks the main thread on ANOTHER process must be bounded.**
  A synchronous **Apple event** also spins a NESTED event loop while it waits, so
  timers keep firing inside it and re-enter Lua mid-call -- the symptom is a
  freeze of tens of seconds that looks like a dead loop but burns ~0% CPU. That
  re-entrancy is specific to Apple events, and the distinction is load-bearing in
  BOTH directions: **AX messaging and `CGWindowListCopyWindowInfo` do NOT pump the
  run loop** (measured -- a 1ms `.common` timer fires 0 times across a third of a
  second of real AX IPC), so they block for latency without ever re-entering. Read
  "blocking" as "must be bounded" everywhere, and "re-entrant" as "Apple events
  only" -- reading it as both is how a re-entrancy bug gets derived for
  `listWindows`, which cannot have one. Two rules hold the line, and a new
  call site must not sidestep them: every synchronous AppleScript goes through
  `Native+AppleScript.runAppleScript`, which liveness-gates the target via
  `requiring:` and imposes a `with timeout` ceiling (never `NSAppleScript` bare --
  a test enforces this); and AX messaging is time-boxed process-wide once at boot
  (`Native+Windows.applyAXMessagingTimeout`). **Bound the wait; do not suppress
  the caller.** Skipping timer ticks during a blocking call was tried and
  reverted: it silently loses work, because a repeating timer is not always a
  resumable poll (count_down counts ticks; sleep_schedule fires inside a narrow
  window). Prefer the ASYNC out-of-process shape for anything bigger than one
  property read -- a subprocess cannot hang the host at all. **A subprocess whose
  output or exit status we CONSUME goes through `Native+Process.runProcessCore`**
  (`runJXA` and the `exec` capability's `run_process` both ride it): it owns the
  concurrent per-stream drains, the exactly-once completion, the pipe RETENTION
  that a lost EOF otherwise turns into a permanently dropped Lua callback, the
  SIGTERM watchdog, and the PINNED stdin (`/dev/null`) and cwd (`/`) -- both are
  inherited otherwise, so an unpinned child reads the developer's terminal under
  `scripts/app.sh` and resolves a relative path against a different directory
  than it will from Finder. A hand-rolled `Process()` re-earns each of those bugs.
  The one exempt shape is launch-and-forget of something that must OUTLIVE the
  host: nothing to drain, and a watchdog would be actively wrong. A couple of
  older sites are NEITHER -- they predate the extraction and still hand-roll it,
  one with a `waitUntilExit()` on the main thread. Do not read them as precedent:
  `testEverySeamSubprocessSiteIsClassified` holds the roster and fails a new spawn
  until it is on the core or written down, checking the per-file COUNT (so a second
  spawn cannot inherit an existing entry's reason) and, for anything staying off the
  core, that it still pins stdin/cwd. Seam failures log via `seamLog` /
  `seamLogThrottled` so they reach the DAILY LOG, not just stdout -- throttled,
  because these sit on poll paths.
  **Timeout values here are MEASURED, not guessed**: the AX default turned out to
  be ~1.5s, so an initial 2s "ceiling" silently loosened it. Re-measure before
  changing one.
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
- **app/platform/swift/McpServer.swift + McpHttp.swift** -- the OPT-IN local MCP
  endpoint (Settings > General > Agent Access) a coding agent connects to for
  the extension-authoring loop: list/describe features, list the ctx surface one
  feature actually receives (`list_api`, over `registry.apiSurface`), reload +
  read load failures, validate one extension's capability declarations, enable a
  feature so it can be test-fired, run an enabled action, tail the log, fetch the
  authoring guide. Every tool must be NAMED in that guide -- a Swift test gates
  it, since the guide is the only documentation an agent reads before calling.
  It grows the agent's REFLECTION, never its reach: there is deliberately no
  eval tool, because arbitrary Lua arriving at runtime is invisible to `capscan`
  and would make `validate_extension`'s verdict meaningless.
  HOST INFRA, not a seam slice: it CONSUMES the bridge via `LuaState.call`
  (data never enters Lua source) and adds no OS surface for Lua -- it lives
  beside StatusBar, never in `Native+*`. Ships in release (unlike DebugControl)
  but gated three ways: off-by-default preference (`hammerdeck.mcp.enabled`,
  plus `.port`/`.token`), loopback-only bind, bearer token. Stateless
  streamable-HTTP MCP (single JSON responses, no SSE/sessions). The agent guide
  it serves lives at `app/docs/hammerdeck-extension-skill.md` (a valid Claude
  Code SKILL.md, also copy/exportable from Settings); `agent_guide.lua` gates it
  against `manifest.CAPABILITY_METHODS` / `VALID_OPTION_TYPES` so the doc
  cannot drift from the code it teaches.
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
scripts/test-swift.sh  # `swift test` to a log, then the FAILING CASE NAMES -- prefer this
swift test           # integration tests on the REAL bridge (see below -- NOT only for Swift changes)
```

**`swift test` is not only for Swift/seam changes -- a pure-Lua feature can turn
it red.** Two integration tests read the LIVE on-disk catalog rather than any
Swift you edited: `testEveryGalleryFeatureHasAPreview` (a feature with no
`FeatureArchetype` case and no `previewExempt` entry) and
`testFeaturePageRosterMatchesDeclarations` (a `page` in feature.json with no
registered provider, or the reverse). CI runs it bare on every push, so run it
for any new or renamed feature too, not just seam work.

Use `scripts/test-swift.sh` rather than piping `swift test` into a filter. A
pipeline reports the LAST command's status, so `swift test | grep` exits 0 even
on a hard failure, and the filter discards the failing case's name along with
everything else it did not match -- so a failure that never recurs stays
unexplained, its evidence discarded before anyone looked at it. The wrapper
writes the full output to `.build/test-logs/swift-test.log` (previous run kept
alongside), prints the failing case lines, and exits with the real status.

**After a code change, restart the app FOR the user, then WAIT for them to
verify.** When a change is ready to try (a completed edit or logical batch, NOT
after every single tool call), run `./scripts/restart.sh` yourself -- it stops,
rebuilds, and relaunches Hammerdeck so the user never has to restart by hand --
then STOP and let the user verify the behavior in the live app before moving on
(and, as always, before committing -- the restart is a verify convenience, not a
commit signal). The user has standing opt-in to this restart, so it overrides the
"ask before restarting the running instance" caution below for the normal
change-verify loop; still avoid restarting mid-way through work the user is
actively watching without a heads-up.

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

**Temporary Swift instrumentation: use `NSLog`, never `print`.** `app.sh`
launches the app with stdout REDIRECTED to a file, and a redirected stdout is
BLOCK-buffered -- so `print` traces sit in a 4KB buffer and never appear, however
long you wait. That is not a missing log line, it is a log line that lies -- an
empty trace reads as "the callback never fired" and sends the investigation
down the wrong path. `NSLog`
writes unbuffered (and stamps a timestamp + thread, both of which you want when
chasing a race). The seam's own `seamLog`/`seamLogThrottled` are better still --
they reach the daily log -- but they are `@MainActor`, so from a `@Sendable`
completion closure (`Process.terminationHandler`, a `readabilityHandler`, a
URLSession handler) `NSLog` is the one that compiles without a main-actor hop.
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

**Verifying UI pixels? Load the `hammerdeck-visual-check` skill FIRST** -- it
carries the capture loop (`scripts/app.sh start` + `scripts/control.sh`, and
which of `@shot` / `scripts/shot.sh` / `scripts/menu-shot.sh` reaches which
surface). Do NOT drive the live Settings window with osascript clicks/scrolls:
that is a rabbit hole (focus theft, below-the-fold content) the skill exists to
keep you out of. Two rules stay HERE because they bind outside any visual check:
`scripts/control.sh` is single-user -- never batch it into a parallel block --
and don't restart the user's running instance or run the UI tests while they may
be at the keyboard; ask first.

Pixel fixes -- probe before iterating (the project instance of the global
"probe the constraint" rule): a native-AppKit visual fix that misses once is
usually a HARD constraint, not one tweak away. The canonical example is the
menubar shortcut column -- only a native `keyEquivalent` sits flush-right with
the submenu arrows; an `attributedTitle` shortcut can't reach that column and
always floats a fixed gap short (see the StatusBar note in the layer map). When
a menubar/panel pixel fix misses, read the layout model or run ONE throwaway
`scripts/shot.sh` probe to learn what the mechanism physically can/can't do,
pick it once, then implement -- don't trial-and-error.

Z-order (a second hard constraint, learned via window_deck's "return blink"):
other apps' windows CANNOT be reordered atomically -- AXRaise is
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

Load the **`add-hammerdeck-feature` skill** -- the full end-to-end checklist
(feature.json + the `context` vocabulary, the capability gate, the ctx-only rule,
i18n, options, the `test/cases/<id>.lua` case file, `Package.swift` +
`gen-readme-features.py`, the gallery archetype, verification) lives there, kept
next to the code it describes. Features are **autodiscovered** by scanning
`app/features/` for a `<id>/lua/init.lua` -- there is no catalog to edit.

## Status / roadmap

Open work lives in the GitHub issue tracker. The author's working status doc and
design notes are unpublished drafts -- see "Where a document goes" below for
where they sit and why they aren't here. Don't duplicate the backlog in this
file. Among those drafts, `STRATEGY.md` is the product-direction memo (the
story and its weighting, the windows-as-anchor thesis, the build order, the
non-goals): read it BEFORE any positioning, marketing-copy, or
feature-priority work, and when direction changes, EDIT it -- never drift
from it silently.

**Strike a finished item in the SAME commit as the work.** Those drafts include
per-domain action lists (`CODE.md`, `PRODUCT.md`, ...), and "I'll update the list
after" does not happen -- a stale row misdirects the "what should I do next?"
answer built on it, which is the one question these lists exist to answer.
Whoever ships the work is the only
person holding the context needed to strike it correctly -- delete the row, and
put anything worth keeping (what shipped differently, what the item got wrong)
in the same edit.

## Where a document goes (the repo is going PUBLIC -- this rule is load-bearing)

Two folders, told apart by looking -- there is no rules file to decode.

- **`docs/`** -- PUBLIC. Whatever is in here SHIPS. It is currently **EMPTY**, and
  that is deliberate: `docs/` has no git history (it was rewritten out), so the
  first file committed here is public forever and removing it later costs another
  history rewrite. A doc earns its way in ONLY by being checked against the code
  and found true -- an audit of the existing drafts found most of them asserting
  things the code no longer does (a dropped backend still described as live, APIs
  that no longer exist, "not yet built" on features that shipped weeks ago).
  Publish one at a time, as a visible `mv` into `docs/`; never bulk-import.
- **`docs-private/`** -- a gitignored ALIAS to the drafts, which are STORED in the
  author's separate private repo, never here. It must stay ignored: git records a
  symlink as its TARGET PATH, so committing it would publish that repo's location.
  Treat anything behind it as unverified until you check it against the code.
- **No public file may reference a private path.** README and CONTRIBUTING point
  at `CLAUDE.md` and the issue tracker -- both real for anyone who clones. A
  `docs-private/...` citation in a shipped file is a dead link for every reader
  but the author; this rule exists because that mistake was made and caught.
- **`notes/`** -- LOCAL private scratch (gitignored, never committed) for working
  thinking you want sitting next to the code.
- **Commercial docs** (what to charge, who we're up against, how we launch) --
  NOT in this repo, at any path, ever. They belong in the author's separate
  private repo. `scripts/hooks/pre-commit` enforces this.
  **Deleting such a file later does not undo it:** a RENAMED file leaves its
  content behind at the old path, and a DELETED one survives in history where no
  check of the working tree can see it. Only a full history rewrite removes it.
  So the rule is: never commit it in the first place.
