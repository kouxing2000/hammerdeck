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

## Want a feature that isn't in the catalog? Write it as an extension

You do not need a merged PR to get a feature. Point Settings > General at a
folder and Hammerdeck loads **user extensions** from it -- Lua laid out exactly
like a built-in (`<folder>/<id>/lua/init.lua`, plus an optional `feature.json`
and `i18n/`), with the same manifest contract, the same `ctx`, and the same
runtime capability gate. Extensions also get `exec` (`ctx.run`), which
first-party features are forbidden from declaring.

Settings > General > Agent Access can expose a local MCP endpoint so a coding
agent can do the loop for you: read the API surface your feature actually
receives, reload, check the load errors, validate that your declared
capabilities match what the code reaches, then enable it and fire an action. The
authoring guide it serves is a valid `SKILL.md` and is copyable from Settings.

That path is the honest answer to the curation policy below: the catalog stays
small and first-party, and your machine does whatever you want.

## The one rule that keeps the design clean

Only the Swift bridge (`app/platform/swift/LuaState.swift`, `Native.swift` and
its `Native+<domain>.swift` extensions) and the Lua seam
(`app/platform/lua/adapter.lua`) may touch native / macOS APIs. Every feature and
platform module reaches the OS *through that seam* (the scoped `ctx`), never
directly. New OS surface grows in whichever `Native+*` slice fits, or a new one
-- never in a feature. [`CLAUDE.md`](CLAUDE.md) carries the full layer map and
the plugin contract -- read it before your first PR.

## Dev setup

```bash
scripts/app.sh start     # compile CLua + the host, then launch it (menubar hammer icon)
scripts/app.sh stop      # quit it (also: restart, status, logs)
lua test/run.lua         # fast headless Lua/feature tests (Homebrew Lua)
scripts/test-lua.sh      # same suite on the vendored 5.4.7 -- run before committing Lua
scripts/test-swift.sh    # integration tests on the real Swift<->Lua bridge
scripts/check-lua-types.sh   # LuaLS over the workspace at Error level (CI runs it)
```

Three things that surprise people:

- **Build through `scripts/app.sh`, not a bare `swift build`.** On Xcode 27,
  SwiftPM records the deployment target as the linked SDK version, and AppKit
  picks SDK-gated behaviour from it (an oversized popover is how it shows).
  `scripts/lib/sdk-link-flags.sh` holds the linker flags that fix it; `app.sh`,
  `test-swift.sh` and `package.sh` all source it.
- **`swift test` is not only for Swift changes.** Two integration tests read the
  live on-disk catalog, so a pure-Lua feature can turn it red -- a new feature
  with no gallery preview, or a `page` in `feature.json` with no registered
  provider. Run it for any new or renamed feature.
- **Use `scripts/test-swift.sh`, not `swift test | grep`.** A pipeline reports
  the last command's status, so the filter swallows both the failure and the
  name of the case that failed. The wrapper writes the full log, prints the
  failing cases, and exits with the real status.

`swift test` is quiet by default: tests that show panels, synthesize keystrokes,
or touch the Keychain are skipped so they don't type into whatever app you have
focused. Run those only when you're away from the keyboard, with
`HAMMERDECK_UI_TESTS=1 scripts/test-swift.sh`.

Keep all Lua **5.4-compatible** (the embedded engine is vendored Lua 5.4.7, even
though your local `lua` may be newer). Run the relevant tests before you open a PR.

## License

By contributing, you agree that your contributions are licensed under the
project's **GPL-3.0** license.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
