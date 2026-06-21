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

/// Whether to greet the user with the Homepage on launch: only on the very
/// first run (the `hammerdeck.firstRun.done` flag is still unset), and never
/// when first-run is suppressed (CI / smoke tests). Pure so it's testable
/// without booting the GUI. Read the flag BEFORE bootLua -- the Lua boot flips
/// it during startup.
func shouldGreetWithHomepage(noFirstRunEnv: String?, firstRunDone: Bool) -> Bool {
    noFirstRunEnv == nil && !firstRunDone
}

/// The "Show in Dock" preference: whether Hammerdeck keeps a Dock icon (and a
/// Cmd-Tab entry) or stays a pure menubar accessory. Default ON -- the Homepage
/// is the app's front door, so a fresh install is easy to find; the user can
/// turn it off from the menu to reclaim the clean menubar-only feel.
///
/// `.regular` = Dock icon present; `.accessory` = menubar-only. Switchable live.
enum DockPreference {
    static let key = "hammerdeck.showInDock"

    /// Unset key counts as ON (the default), so first launch shows in the Dock.
    static var showInDock: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }

    /// Apply the current preference to the running app. Safe to call repeatedly.
    @MainActor static func apply() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}

/// Build the Dock icon at runtime. `swift run` produces a bare executable with
/// no bundle/.icns, so macOS shows a generic "exec" tile; setting
/// `NSApp.applicationIconImage` overrides it for the running process. We prefer
/// the designed artwork (`design/AppIcon.png` -- the hammer-on-fanned-deck mark,
/// transparent corners) and fall back to drawing the menubar hammer on an accent
/// squircle if the file is missing. For a shipped `.app`, generate a real `.icns`
/// from the same PNG and set `CFBundleIconFile` in the bundle instead.
@MainActor
func makeDockIcon() -> NSImage {
    // The designed icon lives at the repo root (resolved from this file's path so
    // it works regardless of the launch working directory).
    let artwork = URL(fileURLWithPath: #filePath)   // .../Sources/HammerdeckKit/Boot.swift
        .deletingLastPathComponent()                 // .../Sources/HammerdeckKit
        .deletingLastPathComponent()                 // .../Sources
        .deletingLastPathComponent()                 // repo root
        .appendingPathComponent("design/AppIcon.png")
    if let designed = NSImage(contentsOf: artwork) {
        return designed
    }

    // Fallback: draw the hammer identity procedurally.
    let side: CGFloat = 512
    let size = NSSize(width: side, height: side)
    let icon = NSImage(size: size)
    icon.lockFocus()

    // rounded-rect "squircle" background, inset to leave the usual icon margin
    let bg = NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: 36, dy: 36)
    let radius = bg.width * 0.22
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: bg, xRadius: radius, yRadius: radius).fill()

    // hammer glyph, forced white via a palette symbol configuration, centered
    let cfg = NSImage.SymbolConfiguration(pointSize: 260, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let hammer = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Hammerdeck")?
        .withSymbolConfiguration(cfg) {
        let s = hammer.size
        hammer.draw(in: NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2,
                               width: s.width, height: s.height))
    }

    icon.unlockFocus()
    return icon
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
    DockPreference.apply()   // .regular (Dock icon) or .accessory (menubar-only)
    app.applicationIconImage = makeDockIcon()   // replace the generic "exec" tile

    let lua = LuaState()
    Native.shared.attach(lua)
    Native.shared.installBindings()

    // Capture first-launch state BEFORE bootLua -- the Lua boot flips the same
    // `hammerdeck.firstRun.done` flag during startup. On first run we greet the
    // user with the Homepage (onboarding); later launches stay quiet.
    let isFirstRun = shouldGreetWithHomepage(
        noFirstRunEnv: ProcessInfo.processInfo.environment["HAMMERDECK_NO_FIRSTRUN"],
        firstRunDone: UserDefaults.standard.bool(forKey: "hammerdeck.firstRun.done"))

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

    // Dev convenience (DEBUG only): seed text_actions' OpenAI key from a
    // gitignored repo-root .env so `swift run` doesn't need a manual paste.
    #if DEBUG
    DevEnv.seed(store)
    #endif

    // The Homepage shell docks the Dashboard + Gallery / Shortcut Map / Timeline
    // / Settings tabs in one window. A Gallery card click deep-links straight to
    // the embedded Settings tab focused on that feature (handled inside the shell).
    let homepageWindow = HomepageWindow(store: store)
    let statusBar = StatusBarController(
        store: store,
        openHome: { homepageWindow.show($0) })
    // The status bar controller doubles as the app delegate so clicking the Dock
    // icon (when shown) reopens the Homepage -- the point of having the icon.
    app.delegate = statusBar

    // First launch: open the Homepage so a new user lands on "here's what
    // Hammerdeck can do," not a bare menubar icon. Every later launch stays
    // quiet (it's "Home…" in the menu) -- a login-item menubar app must not
    // throw a window up on every boot.
    if isFirstRun {
        homepageWindow.show(.home)
    }

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
