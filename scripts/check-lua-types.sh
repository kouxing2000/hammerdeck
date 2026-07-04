#!/bin/bash
# LuaLS type-check gate -- the STATIC half of the token-typo net (the runtime
# half is the seam's loud asserts). Catches at edit/CI time what the enum
# annotations declare: a `"previous"` passed where ---@enum ScreenDir is
# expected, a nil flowing into a frame parameter, an os.date union misused.
#
# Regenerates .luals-stubs/ first: 2-line `---@meta <name>` redirects that map
# the loader's stable require names (platform.*, features.<id>.*) onto their
# co-located lua/ files. The custom package.searcher in app/loader.lua strips
# a prefix no runtime.path pattern can express, so WITHOUT these stubs the
# language server silently resolves no cross-module require at all -- every
# ---@param/---@enum contract goes unchecked (how it was from the 2026-06-24
# co-location refactor until 2026-07-03). Stubs are generated, gitignored
# throwaways -- never edit them.
#
# Severity: runs at Error level; the type-mismatch family is escalated to
# Error in .luarc.json. Warning level still carries ~200 advisory
# need-check-nil/undefined-field findings -- tighten later if wanted.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v lua-language-server >/dev/null 2>&1; then
    echo "check-lua-types: lua-language-server not found (brew install lua-language-server)" >&2
    exit 1
fi

rm -rf .luals-stubs
mkdir -p .luals-stubs
for f in app/platform/lua/*.lua; do
    name="$(basename "$f" .lua)"
    printf -- '---@meta platform.%s\nreturn require("app.platform.lua.%s")\n' \
        "$name" "$name" > ".luals-stubs/platform.$name.lua"
done
for d in app/features/*/; do
    id="$(basename "$d")"
    [ -f "${d}lua/init.lua" ] || continue
    for f in "${d}"lua/*.lua; do
        name="$(basename "$f" .lua)"
        mod="features.$id"
        src="app.features.$id.lua.$name"
        [ "$name" != "init" ] && mod="$mod.$name"
        printf -- '---@meta %s\nreturn require("%s")\n' "$mod" "$src" \
            > ".luals-stubs/$mod.lua"
    done
done

# Gate on the exit code (0 = clean, 1 = problems -- the stable contract),
# not on grepping the English summary line, which a reword/locale could break.
if out="$(lua-language-server --check . --checklevel=Error \
        --logpath="${TMPDIR:-/tmp}/hammerdeck-luals" 2>&1)"; then
    echo "check-lua-types: OK (no problems at Error level)"
else
    echo "$out"
    echo "check-lua-types: FAILED" >&2
    exit 1
fi
