import AppKit

// Hammerdeck native host boot: embeds the Lua platform against the native
// backend (Native.swift) and runs the app loop. Lives in the Kit (not the
// executable) so the integration tests can boot the same stack in-process.

/// Locate the Lua payload: env override first (packaging, tests), then the
/// dev-checkout fallback derived from this source file's location.
func defaultLuaDir() -> String {
    if let env = ProcessInfo.processInfo.environment["HAMMERDECK_LUA_DIR"] {
        return env
    }
    return URL(fileURLWithPath: #filePath)          // .../Sources/HammerdeckKit/Boot.swift
        .deletingLastPathComponent()                 // .../Sources/HammerdeckKit
        .deletingLastPathComponent()                 // .../Sources
        .deletingLastPathComponent()                 // repo root
        .appendingPathComponent("lua").path
}

/// Wire package.path and run the platform entry point on an attached LuaState.
@MainActor
func bootLua(_ lua: LuaState, luaDir: String) throws {
    let escaped = luaDir.replacingOccurrences(of: "'", with: "\\'")
    try lua.run("package.path = package.path .. ';\(escaped)/?.lua;\(escaped)/?/init.lua'")
    try lua.runFile(luaDir + "/hammerdeck.lua")
}

/// The whole app. The executable target's main.swift just calls this.
@MainActor
public func hammerdeckMain() {
    // The app object must exist before any panel is created by feature start().
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let lua = LuaState()
    Native.shared.attach(lua)
    Native.shared.installBindings()

    do {
        try bootLua(lua, luaDir: defaultLuaDir())
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

    // Headless verification: dump the bindable hotkey names (and count), then exit.
    if ProcessInfo.processInfo.environment["HAMMERDECK_DUMP_KEYS"] != nil {
        let names = HotkeyCenter.keyCodes.keys.sorted()
        print("[hammerdeck] bindable keys: \(names.count)")
        print(names.joined(separator: " "))
        exit(0)
    }

    let settingsWindow = SettingsWindow(store: store)
    let shortcutMapWindow = ShortcutMapWindow(store: store)
    let timelineWindow = AutomationTimelineWindow(store: store)
    let statusBar = StatusBarController(
        store: store,
        openSettings: { settingsWindow.show() },
        openShortcutMap: { shortcutMapWindow.show() },
        openTimeline: { timelineWindow.show() })
    _ = statusBar

    // Debug-only: a file-polled Lua control channel for visual verification
    // (off unless HAMMERDECK_CONTROL_DIR is set; the launcher sets it).
    DebugControl.startIfRequested(lua)

    // Clean teardown on quit: stop every feature (unbind hotkeys, watchers,
    // timers, panels) before the process exits, instead of relying on the OS to
    // reclaim native resources implicitly.
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            _ = try? Native.shared.lua.eval("require('platform.registry').stopAll(); return true")
        }
    }

    app.run()
}
