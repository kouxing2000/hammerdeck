import CLua
import Foundation

/// A thin, owned wrapper over the Lua 5.4 C API -- our miniature LuaSkin.
///
/// This is the Swift side of the seam. The embedded `lua/platform/adapter.lua`
/// calls functions registered here (the `native` table built by Native.swift);
/// everything macOS-specific lives on the Swift side of this boundary, nothing
/// Lua-specific leaks past it.
///
/// Threading invariant: a single `lua_State` is NOT reentrant. All calls into
/// this instance must be serialized onto the main thread. Every native callback
/// (timer, hotkey, watcher, panel) fires on the main RunLoop, so re-entering
/// Lua from them is safe by construction.

/// LUA_REGISTRYINDEX is a C macro (not imported): -LUAI_MAXSTACK - 1000.
let LUA_REGISTRY_INDEX: Int32 = -1_001_000

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

    /// Evaluate a Lua expression that returns one value; read it back as a
    /// Swift value (bool/Double/String/[Any]/[String: Any]). Used by the
    /// config UI to query the registry over the bridge.
    func eval(_ code: String) throws -> Any? {
        if luaL_loadstring(L, code) != LUA_OK || lua_pcallk(L, 0, 1, 0, 0, nil) != LUA_OK {
            throw popError()
        }
        defer { lua_settop(L, -2) }
        return LuaState.any(L, -1)
    }

    /// Register a native function as a Lua global.
    func register(_ name: String, _ fn: @escaping Function) {
        lua_pushcclosure(L, fn, 0)   // 0 upvalues == lua_pushcfunction
        lua_setglobal(L, name)
    }

    /// Register a table of native functions as a Lua global (e.g. `native`).
    func registerTable(_ name: String, _ fns: [String: Function]) {
        lua_createtable(L, 0, Int32(fns.count))
        for (fname, fn) in fns {
            lua_pushcclosure(L, fn, 0)
            lua_setfield(L, -2, fname)
        }
        lua_setglobal(L, name)
    }

    // MARK: - Callback references (the core bridge problem, solved once)

    /// Take the Lua value at `index` (usually a function argument) and pin it
    /// in the Lua registry so Swift can hold it past the current call.
    func makeRef(at index: Int32) -> Int32 {
        lua_pushvalue(L, index)
        return luaL_ref(L, LUA_REGISTRY_INDEX)
    }

    func releaseRef(_ ref: Int32) {
        luaL_unref(L, LUA_REGISTRY_INDEX, ref)
    }

    /// Invoke a pinned Lua function. `pushArgs` pushes the arguments and
    /// returns how many it pushed. Errors are logged, never propagated -- a
    /// feature callback blowing up must not take the host down.
    func callRef(_ ref: Int32, pushArgs: (OpaquePointer) -> Int32 = { _ in 0 }) {
        lua_rawgeti(L, LUA_REGISTRY_INDEX, lua_Integer(ref))
        let nargs = pushArgs(L)
        if lua_pcallk(L, nargs, 0, 0, 0, nil) != LUA_OK {
            let msg = LuaState.string(L, -1) ?? "unknown Lua error"
            lua_settop(L, -2)
            print("[hammerdeck] lua callback error: \(msg)")
        }
    }

    // MARK: - Stack helpers (used from native functions)

    /// Read a string argument at the given stack index (1-based).
    static func string(_ L: OpaquePointer?, _ index: Int32) -> String? {
        guard lua_type(L, index) == LUA_TSTRING else { return nil }
        guard let c = lua_tolstring(L, index, nil) else { return nil }
        return String(cString: c)
    }

    /// Read an integer argument. nil if absent or not convertible.
    static func int(_ L: OpaquePointer?, _ index: Int32) -> Int? {
        var isnum: Int32 = 0
        let v = lua_tointegerx(L, index, &isnum)
        guard isnum != 0 else { return nil }
        return Int(v)
    }

    static func double(_ L: OpaquePointer?, _ index: Int32) -> Double? {
        var isnum: Int32 = 0
        let v = lua_tonumberx(L, index, &isnum)
        guard isnum != 0 else { return nil }
        return v
    }

    static func bool(_ L: OpaquePointer?, _ index: Int32) -> Bool {
        return lua_toboolean(L, index) != 0
    }

    /// Read a Lua array of strings at `index`.
    static func stringArray(_ L: OpaquePointer?, _ index: Int32) -> [String] {
        guard lua_type(L, index) == LUA_TTABLE else { return [] }
        var out: [String] = []
        let n = lua_rawlen(L, index)
        for i in 1...max(n, 1) where n > 0 {
            lua_rawgeti(L, index, lua_Integer(i))
            if let s = string(L, -1) { out.append(s) }
            lua_settop(L, -2)
        }
        return out
    }

    /// Read a Lua array of tables with string/number/bool fields at `index`.
    static func dictArray(_ L: OpaquePointer?, _ index: Int32) -> [[String: Any]] {
        guard lua_type(L, index) == LUA_TTABLE else { return [] }
        var out: [[String: Any]] = []
        let n = lua_rawlen(L, index)
        guard n > 0 else { return out }
        for i in 1...n {
            lua_rawgeti(L, index, lua_Integer(i))
            if lua_type(L, -1) == LUA_TTABLE {
                var dict: [String: Any] = [:]
                lua_pushnil(L)
                while lua_next(L, -2) != 0 {
                    if let key = string(L, -2) {
                        switch lua_type(L, -1) {
                        case LUA_TSTRING:  dict[key] = string(L, -1)
                        case LUA_TNUMBER:  dict[key] = double(L, -1)
                        case LUA_TBOOLEAN: dict[key] = bool(L, -1)
                        default: break
                        }
                    }
                    lua_settop(L, -2)   // pop value, keep key for next()
                }
                out.append(dict)
            }
            lua_settop(L, -2)
        }
        return out
    }

    /// The `__jsontype` metafield ("array"|"object") on the table at `index`,
    /// or nil if it carries none. The shared array/object disambiguation tag
    /// that `lua/platform/json.lua` sets and honors -- read here so a value's
    /// shape survives the bridge hop (decisive for empty tables).
    static func jsonType(_ L: OpaquePointer?, _ index: Int32) -> String? {
        let abs = lua_absindex(L, index)
        guard lua_getmetatable(L, abs) != 0 else { return nil }
        lua_pushstring(L, "__jsontype")
        lua_rawget(L, -2)
        let t = string(L, -1)
        lua_settop(L, -3)   // pop the field value and the metatable
        return t
    }

    /// Recursively read any Lua value. Tables become [Any] (array-like) or
    /// [String: Any]; the `__jsontype` tag wins when present, so a table tagged
    /// "object" reads as a dict even when empty. An untagged empty table reads
    /// as an empty array (the historical default `json.lua` shares).
    static func any(_ L: OpaquePointer?, _ index: Int32) -> Any? {
        switch lua_type(L, index) {
        case LUA_TBOOLEAN: return bool(L, index)
        case LUA_TNUMBER:  return double(L, index)
        case LUA_TSTRING:  return string(L, index)
        case LUA_TTABLE:
            let abs = lua_absindex(L, index)
            let tag = jsonType(L, abs)
            let n = lua_rawlen(L, abs)
            // Array: tagged "array", or (untagged) a non-empty sequence. NOTE a
            // deliberate strict-producer/lenient-consumer split: json.lua's
            // ENCODER rejects a table that mixes array entries with string keys,
            // but this READER just takes the 1..n part (string keys drop). Keep
            // the asymmetry -- don't "fix" one side to match the other.
            if tag == "array" || (tag != "object" && n > 0) {
                var arr: [Any] = []
                if n > 0 {
                    for i in 1...n {
                        lua_rawgeti(L, abs, lua_Integer(i))
                        arr.append(any(L, -1) ?? NSNull())
                        lua_settop(L, -2)
                    }
                }
                return arr
            }
            // Object: tagged "object" (even if empty), else an untagged empty
            // table -> empty array to match json.lua's historical default.
            if tag != "object" && n == 0 {
                // Distinguish a genuine empty table from a string-keyed map.
                lua_pushnil(L)
                let hasKey = lua_next(L, abs) != 0
                if hasKey { lua_settop(L, -3) }   // pop value+key from lua_next
                if !hasKey { return [Any]() }     // truly empty -> array default
            }
            var dict: [String: Any] = [:]
            lua_pushnil(L)
            while lua_next(L, abs) != 0 {
                if let key = string(L, -2), let value = any(L, -1) {
                    dict[key] = value
                }
                lua_settop(L, -2)   // pop value, keep key for next()
            }
            return dict
        default:
            return nil
        }
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
