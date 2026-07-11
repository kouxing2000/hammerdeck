# Contributing to Hammerdeck

Thanks for your interest! Hammerdeck is a single-author, first-party feature
platform for macOS -- a curated catalog, **not** a third-party marketplace. That
shapes what's easy to contribute:

## What's welcome

- **Bug reports** -- open an issue with steps to reproduce, your macOS version,
  and a log snippet (menubar -> "Open Logs", or
  `~/Library/Application Support/Hammerdeck/logs/`).
- **Bug fixes** -- PRs that fix a reported bug are very welcome.
- **Docs, tests, and small quality-of-life improvements.**

## What to discuss first

- **New features.** The catalog is curated and first-party by design, so an
  unsolicited new-feature PR may not be merged. Please **open an issue first** to
  talk it through -- it saves you from building something that doesn't fit the
  direction.

## The one rule that keeps the design clean

Only the Swift bridge (`app/platform/swift/LuaState.swift` + `Native.swift`) and
the Lua seam (`app/platform/lua/adapter.lua`) may touch native / macOS APIs.
Every feature and platform module reaches the OS *through that seam* (the scoped
`ctx`), never directly. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[`docs/PLUGIN_SYSTEM.md`](docs/PLUGIN_SYSTEM.md).

## Dev setup

```bash
swift build            # compile CLua + the host
swift run              # run the app (menubar hammer icon)
lua test/run.lua       # fast headless Lua/feature tests (Homebrew Lua)
scripts/test-lua.sh    # same suite on the vendored 5.4.7 -- run before committing Lua
swift test             # integration tests against the real Swift<->Lua bridge
```

Keep all Lua **5.4-compatible** (the embedded engine is vendored Lua 5.4.7, even
though your local `lua` may be newer). Run the relevant tests before you open a PR.

## License

By contributing, you agree that your contributions are licensed under the
project's **GPL-3.0** license.
