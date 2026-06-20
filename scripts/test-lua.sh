#!/usr/bin/env bash
#
# Run the headless Lua test suite against the EXACT engine the app embeds:
# Lua 5.4.7 compiled from Sources/CLua -- NOT the dev machine's Homebrew Lua
# (currently 5.5). This closes the version-skew gap: a 5.4-incompatible
# construct that 5.5 happens to accept will fail here, where it matters.
#
# `lua test/run.lua` (Homebrew) stays the fast inner-loop check; run THIS before
# committing Lua changes and in CI for the authoritative result.
#
# Builds a tiny standalone interpreter (scripts/clua_runner.c + Sources/CLua)
# into .build/ and caches it, rebuilding only when sources change.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=".build/clua-host"
BIN="$BUILD/lua54"
RUNNER="scripts/clua_runner.c"
mkdir -p "$BUILD"

# Cache keys on source mtimes only -- if you change the compiler or the flags
# below, delete the binary ("rm .build/clua-host/lua54") to force a clean rebuild.
needs_build=0
if [ ! -x "$BIN" ]; then
    needs_build=1
elif [ -n "$(find Sources/CLua "$RUNNER" -newer "$BIN" 2>/dev/null | head -n1)" ]; then
    needs_build=1
fi

if [ "$needs_build" -eq 1 ]; then
    echo "building Lua 5.4.7 host interpreter from Sources/CLua ..."
    # Same flag the app's CLua target uses (Package.swift): -DLUA_USE_MACOSX.
    cc -O2 -DLUA_USE_MACOSX -ISources/CLua/include \
        -o "$BIN" "$RUNNER" Sources/CLua/*.c -lm
fi

# test/run.lua prints the live _VERSION in its final line, so the engine that
# actually ran is visible (expect "Lua 5.4", vs "Lua 5.5" from Homebrew).
exec "$BIN" test/run.lua "$@"
