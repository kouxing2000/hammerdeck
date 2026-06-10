# Hammerdeck

Personal macOS feature platform on Hammerspoon. Lowers the bar from "write Lua"
to **config-and-select**: toggle features, set options, bind each to a
shortcut/schedule/event. Single-author, first-party catalog -- NOT a third-party
marketplace.

## The one inviolable rule

**Only `platform/adapter.lua` may call `hs.*`.** Features and every other
platform module go through the adapter. This keeps the Hammerspoon backend
swappable (stock HS now; possibly a native Swift+Lua shell if it ever ships as a
product). If you need an `hs.something` elsewhere, add a method to the adapter
instead of reaching past the seam.

## Layers (top depends on bottom only)

`features/*` -> `registry` -> `triggers` / `manifest` -> `adapter` -> `hs.*`

- **features/** -- logic only; declares a manifest, receives `ctx` (`ctx.opt`,
  `ctx.adapter`, `ctx.log`). Never imports hs.* or platform internals.
- **manifest.lua** -- validates a feature's declared shape; resolves option defaults.
- **triggers.lua** -- turns a declarative trigger spec into a live binding. Any
  trigger can fire any action (the core idea). Types: hotkey, schedule
  (everyMin / at), event (sleep|wake|screenLock|screenUnlock).
- **registry.lua** -- registers features, persists enabled-state + option values
  per id, binds trigger->action.
- **adapter.lua** -- the seam.

## Adding a feature

Copy `features/hello.lua`, fill in id/name/options/defaultTrigger/action, add
`"features.<name>"` to `CATALOG` in `init.lua`.

## Testing

No real backend in CI -- syntax-check with `luac -p` (or `lua` if installed).
Manual verification = load via `~/.hammerspoon`, reload, fire the trigger,
confirm behavior (notification/log).

## Status / next

Scaffold with one demo feature working end-to-end. Next: `hs.webview` config
panel (through the adapter), auto-discover `features/*`, then port real features
(rest timer, sleep schedule, usage widget, tab jumper) from the myHammerSpoon
config. See `docs/ARCHITECTURE.md`.
