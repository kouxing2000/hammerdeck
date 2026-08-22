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
- `commands` — ADDITIVE: injects `ctx.commands()` / `ctx.runCommand()`
  (cross-feature reach; almost never needed by an extension)

The reach is transitive: `platform.favicons` downloads icons through ctx, so a
feature using it needs `network` + `browser` + `files` too.

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
--header "Authorization: Bearer <token>"`), iterate like this:

1. `get_extensions_dir` — where to write. If unset, ask the user to pick a
   folder in Settings > General > Extensions.
2. Write/edit the extension files on disk yourself.
3. `reload` — re-scans the folder. Read the returned load/start failures;
   fix and reload until clean.
4. `validate_extension` — check the `capabilities` in your feature.json against
   what your code actually calls. It reports both directions: `underDeclared`
   (a gated method you call but never declared — the runtime gate will raise on
   whichever branch reaches it, which may not be one you test) and
   `overDeclared` (a capability you claim and never use — the list is only worth
   reading if it is true). Fix both before handing the extension over; `reload`
   proves it LOADS, this proves it declared itself honestly.
5. Ask the user to enable the feature in Settings (there is deliberately no
   enable tool — enabling is the user's choice).
6. `run_action` — test-fire an enabled feature's action.
7. `read_log` — check your `ctx.log` traces and any fire errors.
8. `list_features` / `describe_feature` — verify how the catalog sees it
   (options, triggers, the `extension` flag).

A broken extension never crashes the app — it shows as a failed row with the
error string, and `reload` reports exactly why.
