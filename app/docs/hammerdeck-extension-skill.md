---
name: hammerdeck-extensions
description: Author Hammerdeck user extensions — Lua 5.4 features loaded from the user's extensions folder. Use when writing, debugging, or iterating on a Hammerdeck extension, or when connected to Hammerdeck's MCP server.
---

# Authoring Hammerdeck extensions

Hammerdeck is a macOS feature platform: a native Swift host embedding Lua 5.4.
A **user extension** is a feature you (the agent) can author as plain Lua files
in the user's extensions folder. It gets the exact same contract as a built-in
feature: the same manifest shape, the same `ctx` API, the same capability gate.
Extensions are Lua-only — they cannot contribute native (Swift) UI.

## Where extensions live

The user picks one folder in **Settings > General > Extensions** (the
`hammerdeck.extensionsDir` setting). You never change that setting yourself —
if it is unset, ask the user to pick a folder. Each extension is one subfolder:

```
<extensionsDir>/
  my_feature/                 <- folder name IS the feature id
    lua/
      init.lua                <- required: returns the manifest table
      helper.lua              <- optional siblings, require("extensions.my_feature.helper")
    feature.json              <- optional: declarative identity/presentation
    i18n/
      zh-Hans.json            <- optional translations
```

Hard rules, enforced at load time:
- The manifest `id` must equal the folder name, or the load is refused.
- The folder name must not contain a dot (`.`) — it maps onto the
  `extensions.<id>.*` Lua module namespace.
- Everything must be **Lua 5.4** compatible (the embedded engine is 5.4.7).

## The manifest (`lua/init.lua` returns a table)

```lua
return {
    api = 1,                      -- required: the ctx contract version
    id  = "my_feature",           -- required: == folder name

    -- EITHER the single-action sugar:
    defaultTrigger = { type = "hotkey", mods = { "cmd", "alt" }, key = "k" },
    action = function(ctx) ctx.notify("Hi", "it works") end,

    -- OR an explicit actions list (several independently bindable shortcuts):
    -- actions = {
    --   { id = "start", label = "Start thing",
    --     defaultTrigger = { type = "hotkey", mods = {"cmd","alt"}, key = "s" },
    --     run = function(ctx) ... end },
    --   { id = "refresh", label = "Refresh now", automatable = true,
    --     run = function(ctx) ... end },
    -- },

    -- OR a long-running SERVICE (may also declare actions):
    -- start = function(ctx) ctx.everySeconds(60, function() ... end) end,
    -- stop  = function(ctx) ... end,   -- optional; scoped teardown is automatic

    options = {
        { key = "greeting", type = "string", default = "hello", label = "Greeting" },
    },
}
```

Notes:
- An action without a `defaultTrigger` is dormant until the user binds one.
- `automatable = true` opts an action into AUTOMATED triggers (`schedule` /
  `event`). Leave it off for anything reading live context (selection, focused
  window, clipboard) — those are manual-only (`hotkey` / `chord`).
- Trigger spec shapes:
  - `{ type = "hotkey", mods = {"cmd","alt","shift","ctrl"...}, key = "k" }`
  - `{ type = "chord", mods = {...}, key = "a", follows = {"b"} }` (prefix, then keys)
  - `{ type = "schedule", everyMin = 30 }` or `{ type = "schedule", at = "21:30" }`
  - `{ type = "event", event = "sleep|wake|screenLock|screenUnlock|screenChanged" }`
- Option `type` must be one of: `bool`, `int` (`min`/`max`), `string`
  (`multiline` for lists-one-per-line), `enum` (`values`, optional `labels`),
  `time` ("HH:MM"), `appList`, `siteList`, `placementList`, `aliasList`,
  `secret` (login Keychain; never declare a plaintext `default`). The Settings
  form is GENERATED from this list — no UI code exists or is needed.
- Read options with `ctx.opt("greeting")`; secrets with `ctx.secret(key)`.

## feature.json (optional, but recommended)

Declarative identity, overlaid onto the manifest at load time. It answers
"what can this thing do to my machine?" without reading code:

```json
{
  "name": "My Feature",
  "version": "1.0.0",
  "description": "One sentence of what it does.",
  "category": "utilities",
  "context": "anywhere",
  "capabilities": ["network"]
}
```

- `category`: `windows|switching|text|health|utilities|visibility|appearance|general`
- `context`: `textField|window|web|anywhere|automatic`

## Capabilities — declare what you reach

The ordinary ctx surface (windows, panels, timers, options, clipboard, the
app's own dataDir) is free. Anything beyond it must be NAMED in
`capabilities`, or the method is replaced by a raising stub whose error names
the feature, the method, and the capability to add:

- `input`   — synthesize keystrokes (`ctx.keyStroke`, `ctx.typeText`)
- `network` — outbound HTTP / downloads
- `power`   — sleep / lock / display off / screensaver
- `browser` — read or drive the browser (tabs, URLs, favicons)
- `files`   — filesystem beyond the app's own dataDir (incl. `ctx.homeDir`)
- `apps`    — enumerate installed applications
- `exec`    — run another program (`ctx.run`) — see below
- `commands` — ADDITIVE: injects `ctx.commands()` / `ctx.runCommand()`
  (cross-feature reach; almost never needed by an extension)

The reach is transitive: `platform.favicons` downloads icons through ctx, so a
feature using it needs `network` + `browser` + `files` too.

### `exec` — running a program

```lua
ctx.run("/usr/bin/git", { "-C", "/Users/you/repo", "status", "--porcelain" },
        function(code, out, err)
    ctx.log("git exited", code, #out, "bytes")
end)
```

The `-C` is not decoration: the child runs from `/` (below), so a `git` without it
answers `fatal: not a git repository` no matter where you launched Hammerdeck.

`path` must be ABSOLUTE and `args` is an argv array — passing a string raises.
There is no shell, so nothing expands `~`, `*`, `|` or `$VAR`: build the
arguments, do not build a command line. Async, like every other one-shot; the
child is bounded by a timeout, output is captured up to a per-stream ceiling
(both in `Native+Process.swift`), and disabling the feature TERMINATES the child,
not just its callback.

The child also runs WITHOUT Hammerdeck's macOS privacy permissions: it is its own
process as far as macOS is concerned, so a folder behind Full Disk Access reads
as "Operation not permitted", and a command that controls other apps needs its
own permission rather than borrowing Hammerdeck's.

The child starts with stdin on `/dev/null` and its working directory at `/` —
both fixed, so your extension behaves the same however the host was launched.
There is no way to feed it input: pass what it needs as arguments, or write a
file under `ctx.dataDir()` and give it that path. Every path your command touches
must be absolute, including the directory it works in — that is what the `-C`
above is for, and a tool without such a flag needs a `cd` you cannot give it.

Its ENVIRONMENT is inherited from Hammerdeck, and that one is NOT fixed. A
bundled app gets the launchd environment, whose `PATH` has no `/opt/homebrew/bin`
— so a script that works in your terminal can fail in the app the moment it
shells out to a tool it did not name absolutely. Your own `path` argument must
be absolute anyway; make the paths inside your command absolute too.

Both the timeout and that termination reach the process you started and nothing
it spawned — a command that backgrounds work (`something &`) leaves the
background part running. If your command must be stoppable, do not background
inside it.

`code` is the exit status, nil if the program could not be launched at all, or
NEGATIVE if the child was killed by signal `-code` — the timeout or a teardown
cut it short, as opposed to the command choosing to exit with that number.

Every launch writes the executable and its full argument list to the daily log —
that record is the reason this tier goes through the seam at all. **Do not pass
a secret as an argument**; it persists there for the log's retention window.

`os.execute`, `io.popen`, `package.loadlib` and `os.exit` do NOT exist in this
Lua state — they are raising stubs, and no capability declaration brings them
back. The first three are subprocess-grade reach that would bypass the gate;
`os.exit` is there because a feature quitting the host skips every teardown and
reads to the user as a crash. `validate_extension` reports a call to any of them
under `withdrawn` and fails the extension outright. It sees the bracket form too,
so `os["execute"]` is not a way around the check.

Two routes stay open and are CHECKED rather than blocked, so know what you are
doing if you take them: the `native` table is a Lua global, and
`require "platform.adapter"` reaches the whole seam. Neither has a declaration
behind it, so `validate_extension` fails an extension that uses either —
`native.*` under `withdrawn`, the require under `disallowedRequires`. Use `ctx`.

Declaring `exec` is effectively declaring everything: a program you start can do
whatever the person running Hammerdeck can. Reach for a narrower capability when
one fits. First-party catalog features may not declare it at all (a build guard
enforces that) — they grow OS surface in the Swift seam instead.

## Rules that bite

- **Never touch `native.*`, `platform.adapter`, or the stateful platform
  modules** (`registry`, `ctx`, `triggers`, `manifest`, `modal`, `window_ops`,
  `window_history`). Your whole surface is the `ctx` handed to your functions.
  You MAY `require` the pure leaf utils — `platform.json`, `platform.urls`,
  `platform.hotkeys`, `platform.windows`, `platform.cyclingChooser` — plus
  `platform.favicons` (used as `favicons.new(ctx)`).
- **Time**: get "now" only from `ctx.now()` — never bare `os.time()`/`os.date()`
  for the current time (`os.date` is fine for FORMATTING a time you already
  have).
- **Localization**: user-visible strings go through `ctx.t(key, "English
  source", ...)` / `ctx.plural(...)`, with translations in
  `i18n/<locale>.json` (flat key -> string). A template with **2+ slots must
  number them** (`%1$s`, `%2$s`) in the English source AND the translation —
  Lua's own `string.format` cannot reorder and would crash on `%2$s`; only the
  i18n layer handles it. Never `string.format` over a translated template.
- **Logging**: keep terse, permanent `ctx.log(...)` traces of real decisions
  and state transitions — they land in the daily log and are how you (and the
  user) debug a live misbehavior without re-instrumenting.
- Every handle ctx hands out (timers, hotkeys, panels) is scoped: disabling
  the feature stops them all automatically.

## The authoring loop over MCP

When connected to Hammerdeck's MCP server (the user enables it in
Settings > General > Agent Access, then runs the copied
`claude mcp add --transport http hammerdeck http://127.0.0.1:<port>/mcp
--header "Authorization: Bearer <token>"`), iterate like this.
(`get_extension_guide` returns this document, so a session that has it loaded
has already done step 0.)

1. `get_extensions_dir` — where to write. If unset, ask the user to pick a
   folder in Settings > General > Extensions.
2. `list_api` — what `ctx` actually offers this feature. `available` is every
   member it receives; `withheld` names each capability-gated method it does NOT,
   with the capability that unlocks it. Read this BEFORE writing code against
   `ctx`: a withheld method is a raising stub rather than a missing key, so
   nothing you can test at runtime tells you the difference, and an invented
   member is only discovered on whichever branch reaches it. An extension
   receives exactly the surface a built-in with the same declarations does.
3. Write/edit the extension files on disk yourself.
4. `reload` — re-scans the folder. Read the returned load/start failures;
   fix and reload until clean.
5. `validate_extension` — check the `capabilities` in your feature.json against
   what your code actually calls. It reports both directions: `underDeclared`
   (a gated method you call but never declared — the runtime gate will raise on
   whichever branch reaches it, which may not be one you test) and
   `overDeclared` (a capability you claim and never use — the list is only worth
   reading if it is true). Two more fields cover the standard library, which
   reaches the OS around `ctx` entirely: `rawReach` lists calls like `io.open`
   with the tier each needs — those count toward your declaration, though the ctx
   method is better, being the one the runtime can actually withhold — and
   `withdrawn` lists calls to a name this interpreter no longer has, with its
   replacement. A `withdrawn` entry fails on its own and no declaration fixes it;
   rewrite the call. Fix all of it before handing the extension over; `reload`
   proves it LOADS, this proves it declared itself honestly.
6. `set_enabled` — enable it, so it can be test-fired. Enabling a SERVICE runs
   its `start(ctx)`. A feature needing the Accessibility grant still enables —
   enabling is one policy everywhere, and the grant is onboarded at first use —
   but the result carries a `warning` when the grant is missing. Read it: the
   feature is on and bound, and its actions will onboard the grant instead of
   running, so a `run_action` that seems to do nothing is the missing permission
   rather than a bug in your extension. Ask the user to grant it. Disable again
   when you are done if the user had it off.
7. `run_action` — test-fire an enabled feature's action.
8. `read_log` — check your `ctx.log` traces and any fire errors.
9. `list_features` / `describe_feature` — verify how the catalog sees it
   (options, triggers, the `extension` flag).

A broken extension never crashes the app — it shows as a failed row with the
error string, and `reload` reports exactly why.
