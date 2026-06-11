# Vendored: Lua

This directory is **upstream Lua, vendored verbatim** as a SwiftPM C target. It
is *not* Hammerdeck code -- do not hand-edit the `.c`/`.h` files. Treat it as a
read-only third-party dependency pinned to an exact version.

| | |
|---|---|
| Library | Lua |
| Version | **5.4.7** |
| Source | https://www.lua.org/ftp/lua-5.4.7.tar.gz |
| License | MIT (see the copyright notice at the end of `include/lua.h`) |
| Copyright | Copyright (C) 1994-2024 Lua.org, PUC-Rio |

## Layout (how this differs from the upstream tarball)

The upstream `src/` was split to fit a SwiftPM C target:

- `include/` -- the 4 public API headers (`lua.h`, `luaconf.h`, `lualib.h`,
  `lauxlib.h`) plus **`module.modulemap`** (this file is *ours*, the only
  non-upstream file here -- it exposes the C module to Swift).
- everything else (internal `.h` + all `.c`) sits flat in this directory.
- **Removed** from the upstream `src/`: `lua.c` and `luac.c` -- they define their
  own `main()` (the REPL and the bytecode compiler) and would clash with our
  executable's entry point.

Build flags live in `Package.swift` (`-DLUA_USE_MACOSX`, header search path).

## How to bump the version

1. Download the new tarball from https://www.lua.org/ftp/ and extract.
2. Replace all `.c` and `.h` here from the new `src/` **except** keep
   `include/module.modulemap` (ours).
3. Re-apply the layout: move `lua.h luaconf.h lualib.h lauxlib.h` into `include/`;
   delete `lua.c` and `luac.c`.
4. Update the version + source URL in this file.
5. `swift build && swift run` to confirm the bridge still links and runs.

Pin deliberately; do not auto-update. Lua patch releases are rare and stable, but
a bump should be an explicit, tested commit.
