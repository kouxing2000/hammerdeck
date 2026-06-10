import CLua

// Milestone 1: prove the native host embeds Lua and that Lua can call back into
// Swift. This is the skeleton the real adapter bridge grows from -- right now it
// exposes a single `native_log` function and runs an inline Lua chunk.
//
// Next milestones: expose the full adapter surface (bindHotkey, everySeconds,
// onSystemEvent, notify, settings) and load lua/init.lua instead of this inline
// snippet; then add the SwiftUI menubar app + settings window.

let lua = LuaState()

// native_log(msg) -- Lua -> Swift call.
lua.register("native_log") { L in
    let msg = LuaState.string(L, 1) ?? "(nil)"
    print("[lua→swift] \(msg)")
    return 0   // no return values
}

do {
    try lua.run("""
        native_log("embedded Lua 5.4 is running")
        native_log("2 + 2 = " .. (2 + 2))
        for i = 1, 3 do native_log("tick " .. i) end
    """)
    print("[hammerdeck] milestone 1 ok: Swift ran Lua, Lua called Swift")
} catch {
    print("[hammerdeck] FAILED: \(error)")
}
