import AppKit

// Hammerdeck native host: boots the embedded Lua platform against the native
// backend (Native.swift) and runs the app loop. No Hammerspoon anywhere.
//
// M2 Slice 1: hotkeys, timers, system events, settings, toast/banner/chooser UI.
// M2 Slice 2 (pending): AXUIElement window listing for window_jump.
// M3 (pending): menubar presence, app bundle, real Notification Center, signing.

// The app object must exist before any panel is created by feature start().
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let lua = LuaState()
Native.shared.attach(lua)
Native.shared.installBindings()

// Locate the Lua payload: env override first (packaging, tests), then the
// dev-checkout fallback derived from this source file's location.
let luaDir: String = {
    if let env = ProcessInfo.processInfo.environment["HAMMERDECK_LUA_DIR"] {
        return env
    }
    return URL(fileURLWithPath: #filePath)          // .../Sources/Hammerdeck/main.swift
        .deletingLastPathComponent()                 // .../Sources/Hammerdeck
        .deletingLastPathComponent()                 // .../Sources
        .deletingLastPathComponent()                 // repo root
        .appendingPathComponent("lua").path
}()

do {
    let escaped = luaDir.replacingOccurrences(of: "'", with: "\\'")
    try lua.run("package.path = package.path .. ';\(escaped)/?.lua;\(escaped)/?/init.lua'")
    try lua.runFile(luaDir + "/hammerdeck.lua")
} catch {
    print("[hammerdeck] FAILED to boot the Lua platform: \(error)")
    exit(1)
}

// Config UI: menubar entry point + the settings window (config-and-select).
let store = SettingsStore(lua: lua)

// Headless verification: dump the catalog the config UI renders, then exit.
if ProcessInfo.processInfo.environment["HAMMERDECK_DUMP_CATALOG"] != nil {
    store.refresh()
    for f in store.features {
        print("\(f.id) [\(f.category)/\(f.kind)] enabled=\(f.enabled) trigger=\(f.triggerDesc)")
        for o in f.options {
            print("  - \(o.key): \(o.type) (default: \(o.defaultValue ?? "nil"))"
                  + (o.values.isEmpty ? "" : " values=\(o.values)"))
        }
    }
    exit(0)
}

let settingsWindow = SettingsWindow(store: store)
let statusBar = StatusBarController(store: store) { settingsWindow.show() }

app.run()
