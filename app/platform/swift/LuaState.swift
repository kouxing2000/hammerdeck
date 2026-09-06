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

    /// Where `callRef` errors land. Defaults to stdout; the host repoints this
    /// at its durable daily log on attach (Native.attach), so a timer/hotkey/
    /// watcher callback failing while nobody watches still leaves a clue.
    var errorSink: (String) -> Void = { print("[hammerdeck] \($0)") }

    /// The threading invariant made loud: a single `lua_State` is not
    /// reentrant, so every entry must come from the main thread. An off-main
    /// caller would corrupt the state silently -- trap here instead.
    private func assertMainThread() {
        precondition(Thread.isMainThread, "LuaState entered off the main thread")
    }

    init() {
        L = luaL_newstate()
        luaL_openlibs(L)   // base, string, table, math, os, io, ...
        installSubprocessStubs()
    }

    /// Replace the standard-library functions that spawn a subprocess, load
    /// native code, or kill the host with stubs that raise and name the
    /// supported route.
    ///
    /// `luaL_openlibs` hands every feature and extension the WHOLE standard
    /// library, so `os.execute` / `io.popen` were a way to shell out that the
    /// capability gate never saw: no declaration in feature.json, no line in the
    /// daily log, invisible to capscan -- and synchronous on the main thread with
    /// no timeout, which is the freeze class Native+AppleScript.runAppleScript
    /// exists to prevent. `ctx.run` (the `exec` capability) is the declared,
    /// async, logged replacement.
    ///
    /// This does NOT make ctx.run the only route to a child process, and no
    /// comment here should say it does. `native` is a plain Lua global
    /// (`registerTable` -> `lua_setglobal`), so `native.run_process` reaches the
    /// seam with no declaration at all, and `require "platform.adapter"` reaches
    /// all of it; capscan reports both, and `validateExtension` fails on them,
    /// but that is a STATIC verdict an author can be shown, not a gate the
    /// runtime enforces. `package.loadlib` below is advisory in the same way:
    /// `require`'s C searcher loads a cpath dylib through an internal path that
    /// never calls the Lua-visible function.
    ///
    /// A raising STUB, never a nil -- the same idiom the capability gate uses for
    /// a withheld ctx method. `attempt to call a nil value (field 'execute')`
    /// tells an author nothing; this names the replacement and the file to edit.
    ///
    /// `package.loadlib` goes with them: it links an arbitrary dylib and runs its
    /// constructors on load, which is a subprocess-grade capability wearing a
    /// different name.
    ///
    /// `os.exit` is here for a different reason -- not reach, but blast radius.
    /// It takes the whole host down from inside a feature callback, skipping
    /// every teardown, and there is no ctx equivalent because quitting the app is
    /// not a thing a feature gets to decide. A stray one in an extension would
    /// read to the user as Hammerdeck crashing.
    ///
    /// Nothing in the app uses any of the four. Only these four: the platform
    /// itself needs `io.open` / `os.remove` / `os.rename` / `loadfile`
    /// (adapter.lua, i18n.lua, loader.lua), so they stay and capscan reports them
    /// as `files`-tier reach instead. This is not a sandbox and does not pretend
    /// to be one -- `load()` alone defeats any static scan.
    private func installSubprocessStubs() {
        let advice = "declare the \"exec\" capability in feature.json and call "
                   + "ctx.run(absolutePath, args, cb)"
        let src = """
        local function blocked(name, why)
            return function()
                error(name .. ' is not available in Hammerdeck -- ' .. why, 2)
            end
        end
        os.execute = blocked('os.execute',
            [[\(advice)]] .. ' -- it is async and timed out, where os.execute blocks the whole app')
        io.popen = blocked('io.popen',
            [[\(advice)]] .. ' -- its callback receives stdout and stderr')
        package.loadlib = blocked('package.loadlib',
            [[\(advice)]] .. ' -- ship the code as a helper binary and run it, rather than '
            .. 'linking a library into the host')
        os.exit = blocked('os.exit',
            'a feature cannot quit the app: it would skip every teardown and read to the '
            .. 'user as a crash. Stop your own work instead -- return from the action, or '
            .. 'stop() the handles you hold')
        """
        if luaL_loadstring(L, src) != LUA_OK || lua_pcallk(L, 0, 0, 0, 0, nil) != LUA_OK {
            // Unreachable short of a broken build: the chunk is a constant. Crash
            // rather than boot a state where the two functions are still live.
            preconditionFailure("subprocess stubs not installed: \(popError())")
        }
    }

    deinit {
        lua_close(L)
    }

    /// Run a chunk of Lua source. Throws with the Lua error message on failure.
    func run(_ code: String) throws {
        assertMainThread()
        // luaL_dostring / lua_pcall are C macros (not imported to Swift), so we
        // spell them out: load the chunk, then protected-call it.
        if luaL_loadstring(L, code) != LUA_OK || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil) != LUA_OK {
            throw popError()
        }
    }

    /// Run a Lua file by path.
    func runFile(_ path: String) throws {
        assertMainThread()
        if luaL_loadfilex(L, path, nil) != LUA_OK || lua_pcallk(L, 0, LUA_MULTRET, 0, 0, nil) != LUA_OK {
            throw popError()
        }
    }

    /// Evaluate a Lua expression that returns one value; read it back as a
    /// Swift value (bool/Double/String/[Any]/[String: Any]). Used by the
    /// config UI to query the registry over the bridge.
    func eval(_ code: String) throws -> Any? {
        assertMainThread()
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

    /// Current Lua stack depth. For tests/diagnostics -- a call that leaks or
    /// over-pops the stack is a classic C-API bug, so tests assert this is
    /// unchanged across `call`.
    var stackTop: Int { Int(lua_gettop(L)) }

    // MARK: - Typed calls (marshalled args -- never Lua source)

    /// Call `require(module).function(args...)` and return its results, marshalling
    /// each argument straight onto the Lua stack as a real value. Unlike `eval`,
    /// DATA never enters Lua source, so there is no escaping/injection surface --
    /// the config layer hands over Swift values, not hand-built Lua table literals.
    /// Only the module/function NAMES (code constants) identify the target. Throws
    /// the Lua error on a require/call failure; the stack is restored on every path.
    ///
    /// Returns exactly `results` values (Lua nil-pads/truncates to fit) -- there is
    /// no MULTRET "all returns" mode; pass the count you read. Like the rest of the
    /// bridge it assumes the default Lua stack headroom (LUA_MINSTACK) -- fine for
    /// the shallow arg shapes callers pass, not a deep-recursion marshaller.
    @discardableResult
    func call(_ module: String, _ function: String,
              _ args: [LuaArg] = [], results: Int32 = 1) throws -> [Any?] {
        assertMainThread()
        let base = lua_gettop(L)
        // require(module) -> module table on top
        lua_getglobal(L, "require")
        lua_pushstring(L, module)
        if lua_pcallk(L, 1, 1, 0, 0, nil) != LUA_OK {
            let e = popError(); lua_settop(L, base); throw e
        }
        // module[function], then drop the module table so the function sits
        // directly above the args (where lua_pcallk expects it).
        lua_getfield(L, -1, function)
        lua_rotate(L, base + 1, -1)   // [module, fn] -> [fn, module]
        lua_settop(L, -2)             // pop the module copy
        for a in args { push(a) }
        if lua_pcallk(L, Int32(args.count), results, 0, 0, nil) != LUA_OK {
            let e = popError(); lua_settop(L, base); throw e
        }
        var out: [Any?] = []
        if results > 0 {
            for i in 1...Int(results) { out.append(LuaState.any(L, base + Int32(i))) }
        }
        lua_settop(L, base)           // leave the stack exactly as we found it
        return out
    }

    /// Push one marshalled argument onto the stack (recursive for table/array).
    private func push(_ arg: LuaArg) {
        switch arg {
        case .string(let s): lua_pushstring(L, s)
        case .bool(let b):   lua_pushboolean(L, b ? 1 : 0)
        case .int(let i):    lua_pushinteger(L, lua_Integer(i))
        case .double(let d): lua_pushnumber(L, d)
        case .array(let xs):
            lua_createtable(L, Int32(xs.count), 0)
            for (i, x) in xs.enumerated() {
                push(x)
                lua_rawseti(L, -2, lua_Integer(i + 1))
            }
        case .table(let m):
            lua_createtable(L, 0, Int32(m.count))
            for (k, v) in m {
                push(v)
                lua_setfield(L, -2, k)
            }
        }
    }

    // MARK: - Callback references (the core bridge problem, solved once)

    #if DEBUG
    /// DEBUG: live count of pinned callback refs (makeRef +1 / releaseRef -1). A
    /// count that grows across enable/disable cycles is a leaked Lua registry ref
    /// -- the host's most error-prone bug, the reason the bindObserver /
    /// fireCallback seam helpers exist. Lua's registry exposes no count, so we
    /// track it here; an integration test asserts it returns to baseline. All ref
    /// ops run on the main actor, so a plain Int is safe.
    private(set) var pinnedRefCount = 0
    #endif

    /// Take the Lua value at `index` (usually a function argument) and pin it
    /// in the Lua registry so Swift can hold it past the current call.
    ///
    /// This is the REQUIRED-callback path -- every one of its ~24 callers needs
    /// the value it asked for, so a nil here is a wiring bug and earns one named
    /// line AT CREATION. Not silence: `callRef` now refuses a non-positive ref,
    /// and without this line a typo'd handler would register a global hotkey that
    /// grabs the combo and does nothing, with no trace anywhere. Not per-event
    /// either, which is what calling the nil used to produce.
    ///
    /// An OPTIONAL callback goes through `makeCallbackRef` instead, which returns
    /// LUA_REFNIL quietly -- absence is legitimate there, and it never reaches
    /// this function.
    func makeRef(at index: Int32, file: StaticString = #fileID, line: UInt = #line) -> Int32 {
        assertMainThread()
        lua_pushvalue(L, index)
        let ref = luaL_ref(L, LUA_REGISTRY_INDEX)
        guard ref > 0 else {
            errorSink("required callback at \(file):\(line) is nil -- the binding "
                      + "will register and then do nothing")
            return ref
        }
        #if DEBUG
        pinnedRefCount += 1
        #endif
        return ref
    }

    /// Pin an OPTIONAL Lua callback read from a field or argument.
    ///
    /// Absent or nil pins nothing and `callRef` then refuses it -- the panel
    /// simply has no handler for that event, which is what an optional callback
    /// means. Anything PRESENT but not callable is a wiring mistake, and it earns
    /// exactly one named line here rather than an anonymous "attempt to call a
    /// nil value" at every event for the life of the panel.
    func makeCallbackRef(at index: Int32, named: String) -> Int32 {
        assertMainThread()
        let t = lua_type(L, index)
        if t == LUA_TNIL || t == LUA_TNONE { return LUA_REFNIL }
        guard t == LUA_TFUNCTION else {
            let kind = lua_typename(L, t).map { String(cString: $0) } ?? "?"
            errorSink("callback `\(named)` is a \(kind), not a function -- ignored")
            return LUA_REFNIL
        }
        return makeRef(at: index)
    }

    func releaseRef(_ ref: Int32) {
        assertMainThread()
        // Mirror `makeRef` exactly. Decrementing for a ref that was never pinned
        // drives the counter BELOW baseline, and a negative drift CANCELS a real
        // leak -- the detector would read green on precisely the bug it exists to
        // catch, and no test could see it (the two that read the count are both
        // behind the UI opt-in and skipped in CI).
        //
        // The `> 0` also covers the registry itself: `luaL_unref`'s own guard is
        // `ref >= 0`, so a stray 0 is NOT a no-op -- it writes the freelist head
        // into slot 0 and then points the freelist at 0.
        guard ref > 0 else { return }
        luaL_unref(L, LUA_REGISTRY_INDEX, ref)
        #if DEBUG
        pinnedRefCount -= 1
        #endif
    }

    /// Invoke a pinned Lua function. `pushArgs` pushes the arguments and
    /// returns how many it pushed. Errors are logged, never propagated -- a
    /// feature callback blowing up must not take the host down.
    func callRef(_ ref: Int32, pushArgs: (OpaquePointer) -> Int32 = { _ in 0 }) {
        assertMainThread()
        // `luaL_ref` only ever hands back a POSITIVE registry key, so anything
        // else means "no callback": LUA_REFNIL (-1) from an absent optional
        // field, or the plain 0 at Native+Triggers' absent release handler.
        // Guarding the invariant covers LUA_NOREF and any future spelling too.
        // Silent on purpose -- whichever path produced a non-positive ref has
        // ALREADY logged (makeRef names a required nil, makeCallbackRef names a
        // non-function); logging again here would be per-event. Calling such a
        // ref reaches
        // lua_pcallk with a nil on the stack and logs an error PER EVENT: on a
        // drag handler that is a line per mouse-move, naming neither the field
        // nor the panel.
        guard ref > 0 else { return }
        lua_rawgeti(L, LUA_REGISTRY_INDEX, lua_Integer(ref))
        let nargs = pushArgs(L)
        if lua_pcallk(L, nargs, 0, 0, 0, nil) != LUA_OK {
            let msg = LuaState.string(L, -1) ?? "unknown Lua error"
            lua_settop(L, -2)
            errorSink("lua callback error: \(msg)")
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

    /// Read a boolean argument. nil if the slot is ABSENT or Lua `nil` -- the
    /// same contract as `string`/`int`/`double`, so `?? someDefault` means what
    /// it reads as at every call site.
    ///
    /// Returning a bare `Bool` was the trap: `lua_toboolean` answers 0 for nil
    /// and for absent, so a missing argument was indistinguishable from an
    /// explicit `false`, and `LuaState.bool(L, n) ?? true` compiled into dead
    /// code that silently defaulted the other way. Lua's own truthiness still
    /// governs everything that IS present -- only `false` is false.
    static func bool(_ L: OpaquePointer?, _ index: Int32) -> Bool? {
        let t = lua_type(L, index)
        guard t != LUA_TNIL, t != LUA_TNONE else { return nil }
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

    /// Read a Lua array of integers at `index` (e.g. a set of 1-based indices).
    static func intArray(_ L: OpaquePointer?, _ index: Int32) -> [Int] {
        guard lua_type(L, index) == LUA_TTABLE else { return [] }
        var out: [Int] = []
        let n = lua_rawlen(L, index)
        for i in 1...max(n, 1) where n > 0 {
            lua_rawgeti(L, index, lua_Integer(i))
            if let v = int(L, -1) { out.append(v) }
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
                        case LUA_TBOOLEAN: dict[key] = bool(L, -1) ?? false
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

    /// Deepest table nesting `any` will walk before giving up on a branch.
    ///
    /// MEASURED, not guessed (the same rule the seam's timeouts follow): with all
    /// 26 catalog features registered, `registry.describe()` -- the largest thing
    /// that crosses this bridge -- is 6 levels deep, and a deliberately nested
    /// chain-of-chains effect spec, about the deepest shape a user can build in
    /// the rules UI, is 7. 24 leaves roughly 3x headroom over both while staying
    /// far below anything that threatens the Swift stack. Re-measure before
    /// lowering it.
    private static let maxTableDepth = 24

    /// Recursively read any Lua value. Tables become [Any] (array-like) or
    /// [String: Any]; the `__jsontype` tag wins when present, so a table tagged
    /// "object" reads as a dict even when empty. An untagged empty table reads
    /// as an empty array (the historical default `json.lua` shares).
    static func any(_ L: OpaquePointer?, _ index: Int32, depth: Int = 0) -> Any? {
        switch lua_type(L, index) {
        case LUA_TBOOLEAN: return bool(L, index) ?? false
        case LUA_TNUMBER:  return double(L, index)
        case LUA_TSTRING:  return string(L, index)
        case LUA_TTABLE:
            // A CYCLE is what this bound really buys. `local t = {}; t.me = t`
            // handed to any table-reading binding -- hud_show, http headers,
            // run_process args -- used to recurse until the SWIFT stack
            // overflowed and killed the host outright: no log line, no Lua
            // traceback, nothing to read afterwards. A depth bound catches a
            // cycle and honest over-nesting with one check; pointer tracking
            // would cost a set allocation on every table read to catch strictly
            // less. Nothing the app builds is near this deep, so a payload that
            // trips it is a caller bug -- and losing that branch beats losing
            // the app.
            guard depth < maxTableDepth else { return nil }
            // Each level parks a key AND a value while it recurses, so the 20
            // slots LUA_MINSTACK promises a C function are gone about ten levels
            // down. In a release build the overflow assert is compiled out, so
            // the push lands past the stack top and corrupts it silently instead
            // of raising. Ask for the room rather than assuming it.
            guard lua_checkstack(L, 4) != 0 else { return nil }
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
                        arr.append(any(L, -1, depth: depth + 1) ?? NSNull())
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
                if let key = string(L, -2), let value = any(L, -1, depth: depth + 1) {
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

/// A Swift value that marshals directly into a Lua call argument, so callers
/// hand over data as values instead of building Lua source (no escaping, no
/// injection). Mirrors what `LuaState.any` reads back the other way.
indirect enum LuaArg {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case array([LuaArg])
    case table([String: LuaArg])
}
