import CLua

/// A thin, owned wrapper over the Lua 5.4 C API -- our miniature LuaSkin.
///
/// This is the Swift side of the seam. The embedded Lua `platform/adapter.lua`
/// will call functions registered here; everything macOS-specific lives on the
/// Swift side of this boundary, nothing Lua-specific leaks past it. Keep the
/// surface small and grow it only as the adapter needs new native calls.
///
/// Threading invariant: a single `lua_State` is NOT reentrant. All calls into
/// this instance must be serialized onto one thread (the main thread). Once
/// native timer/hotkey callbacks start dispatching into Lua (Milestone 2),
/// marshal them onto the main thread before re-entering the state.
final class LuaState {
    /// Signature every native function exposed to Lua uses.
    /// Return the number of values you pushed onto the stack as results.
    typealias Function = @convention(c) (OpaquePointer?) -> Int32

    let L: OpaquePointer

    init() {
        L = luaL_newstate()
        luaL_openlibs(L)   // base, string, table, math, os, io, ...
    }

    deinit {
        lua_close(L)
    }

    /// Run a chunk of Lua source. Throws with the Lua error message on failure.
    func run(_ code: String) throws {
        // luaL_dostring / lua_pcall are C macros (not imported to Swift), so we
        // spell them out: load the chunk, then protected-call it.
        if luaL_loadstring(L, code) != LUA_OK || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil) != LUA_OK {
            throw popError()
        }
    }

    /// Run a Lua file by path.
    func runFile(_ path: String) throws {
        if luaL_loadfilex(L, path, nil) != LUA_OK || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil) != LUA_OK {
            throw popError()
        }
    }

    /// Register a native function as a Lua global.
    func register(_ name: String, _ fn: @escaping Function) {
        lua_pushcclosure(L, fn, 0)   // 0 upvalues == lua_pushcfunction
        lua_setglobal(L, name)
    }

    // MARK: - Stack helpers (used from native functions)

    /// Read a string argument at the given stack index (1-based).
    static func string(_ L: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = lua_tolstring(L, index, nil) else { return nil }
        return String(cString: c)
    }

    /// Read an integer argument at the given stack index (1-based).
    /// Returns nil if the value is absent or not convertible to an integer
    /// (so callers can distinguish "missing" from a real 0).
    static func int(_ L: OpaquePointer?, _ index: Int32) -> Int? {
        var isnum: Int32 = 0
        let v = lua_tointegerx(L, index, &isnum)
        guard isnum != 0 else { return nil }
        return Int(v)
    }

    // MARK: - Private

    private func popError() -> LuaError {
        let msg = LuaState.string(L, -1) ?? "unknown Lua error"
        lua_settop(L, -2)   // lua_pop(L, 1)
        return LuaError(message: msg)
    }
}

struct LuaError: Error, CustomStringConvertible {
    let message: String
    var description: String { "Lua error: \(message)" }
}
