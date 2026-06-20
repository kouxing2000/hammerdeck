/* Hammerdeck test tooling -- NOT part of the vendored Lua tree (Sources/CLua).
 *
 * A minimal standalone Lua interpreter built FROM Sources/CLua, i.e. the exact
 * Lua 5.4.7 the app embeds. Upstream's own `lua.c` REPL main was deliberately
 * removed from the vendored tree (it would clash with the app's entry point --
 * see Sources/CLua/VENDOR.md), so this provides just enough of a `main()` to
 * run a script file. It lets the headless Lua suite (test/run.lua) run against
 * the embedded engine instead of the dev machine's Homebrew Lua, closing the
 * version-skew gap. Driven by scripts/test-lua.sh.
 */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s script.lua [args...]\n", argv[0]);
        return 2;
    }
    lua_State *L = luaL_newstate();
    if (L == NULL) {
        fprintf(stderr, "cannot create Lua state (out of memory)\n");
        return 1;
    }
    luaL_openlibs(L);

    /* Expose args as the standard `arg` table: arg[0] = script, arg[1..] rest. */
    lua_createtable(L, argc - 2, 1);
    lua_pushstring(L, argv[1]);
    lua_rawseti(L, -2, 0);
    for (int i = 2; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1);
    }
    lua_setglobal(L, "arg");

    if (luaL_dofile(L, argv[1]) != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "%s\n", msg != NULL ? msg : "(unknown Lua error)");
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
