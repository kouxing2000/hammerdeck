# Hammerdeck

A personal macOS **feature platform** built on Hammerspoon. Instead of writing
Lua for every automation, you **toggle features on/off, set their options, and
bind each to a shortcut, a schedule, or a system event** -- config-and-select,
not code.

> Working name. Rename the folder freely; nothing depends on it yet.

## Status

Early scaffold. The core works end-to-end: a feature declares a **manifest**,
the **registry** binds it, the **trigger layer** fires it, and everything reaches
macOS through a single **adapter** seam (`platform/adapter.lua`) so the
Hammerspoon backend stays swappable. One demo feature (`features/hello.lua`)
proves the loop.

## Try it (development, on stock Hammerspoon)

Add to your real `~/.hammerspoon/init.lua`:

```lua
package.path = package.path .. ";" .. os.getenv("HOME") .. "/workspaces/git/hammerdeck/?.lua"
require("init")
```

Reload Hammerspoon, then press **Cmd+Alt+Ctrl+H** -- you should see a "Hammerdeck"
notification. That's manifest -> registry -> trigger -> action working.

## Design

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The one rule that protects
every future option: **only `platform/adapter.lua` may call `hs.*`.** Everything
else goes through the adapter, so "fork Hammerspoon vs. native Swift shell" later
is a backend swap, not a rewrite.

## Layout

```
init.lua              entry point: registers the catalog, binds enabled features
platform/
  adapter.lua         THE SEAM -- only file allowed to touch hs.*
  manifest.lua        manifest schema + validation
  triggers.lua        universal trigger layer (hotkey | schedule | event)
  registry.lua        available/enabled features; binds trigger -> action
features/
  hello.lua           example feature / template
docs/
  ARCHITECTURE.md
```
