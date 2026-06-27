import AppKit

// Hammerdeck native host boot: embeds the Lua platform against the native
// backend (Native.swift) and runs the app loop. Lives in the Kit (not the
// executable) so the integration tests can boot the same stack in-process.

/// Root that holds the runtime-loaded resources (the Lua payload `app/` and the
/// `design/` artwork). Two homes, probed in order:
///   1. `HAMMERDECK_RESOURCE_DIR` env override -- packaging / tests can point anywhere.
///   2. A packaged `.app`: the build copies these under `Contents/Resources`, so
///      `Bundle.main.resourcePath` is the root (gated on the Lua anchor existing,
///      so a SwiftPM `swift run` -- whose resourcePath is `.build/...` without it --
///      falls through instead of matching a bare binary dir).
///   3. Dev checkout: derive the repo root from THIS source file's location.
/// Both defaultLuaDir() and makeDockIcon() hang off this, so a bundle relocates
/// every runtime resource by changing one function.
func resourceRoot() -> String {
    if let env = ProcessInfo.processInfo.environment["HAMMERDECK_RESOURCE_DIR"] {
        return env
    }
    if let res = Bundle.main.resourcePath,
       FileManager.default.fileExists(atPath: res + "/app/hammerdeck.lua") {
        return res
    }
    return URL(fileURLWithPath: #filePath)          // .../app/platform/swift/Boot.swift
        .deletingLastPathComponent()                 // .../app/platform/swift
        .deletingLastPathComponent()                 // .../app/platform
        .deletingLastPathComponent()                 // .../app
        .deletingLastPathComponent()                 // repo root (holds app/ and design/)
        .path
}

/// Locate the Lua payload: explicit `HAMMERDECK_LUA_DIR` override first (the
/// integration tests pass their own path), then the resource root's `app/`.
func defaultLuaDir() -> String {
    if let env = ProcessInfo.processInfo.environment["HAMMERDECK_LUA_DIR"] {
        return env
    }
    return resourceRoot() + "/app"
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

/// "Caps Lock acts as Hyper (⌘⌥⌃)": when ON, the physical Caps key becomes a
/// momentary Hyper modifier (CapsHyperTap does the work). Default OFF -- it
/// remaps Caps and needs the Accessibility grant, so it stays opt-in. A pure
/// host concern (global input plumbing, no per-action surface), so it mirrors
/// DockPreference rather than living as a Lua feature option.
enum CapsHyperPreference {
    static let key = "hammerdeck.capsHyper"

    /// Unset key counts as OFF (Caps stays a normal Caps Lock until opted in).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }

    /// Apply the current preference. When turning on without the Accessibility
    /// grant the tap can't be created -- prompt and leave the pref ON so it takes
    /// effect on the next apply (after the user grants and relaunches/retoggles).
    @MainActor static func apply() {
        if enabled {
            if !CapsHyperTap.shared.enable() {
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
        } else {
            CapsHyperTap.shared.disable()
        }
    }

    /// A USER-initiated toggle (menu / Settings): persist, apply, and surface an
    /// on-screen notice -- Caps now behaves differently, so a silent flip would
    /// leave the user confused later. Distinct from apply()-on-launch, which must
    /// stay silent (no toast on every boot when it's already on).
    @MainActor static func userToggle(to on: Bool) {
        set(on)
        apply()
        if on {
            if CapsHyperTap.shared.isEnabled {
                Toast.show(title: "Caps Lock → Hyper",
                           text: "Caps Lock now acts as ⌘⌥⌃. Double-tap Caps for normal Caps Lock.",
                           centered: true, seconds: 3)
            } else {
                Toast.show(title: "Caps Lock → Hyper",
                           text: "Grant Accessibility, then toggle again to enable.",
                           centered: true, seconds: 4)
            }
        } else {
            Toast.show(title: "Caps Lock restored",
                       text: "Caps Lock works normally again.",
                       centered: true, seconds: 2)
        }
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
    // The designed icon lives under the resource root (repo root in dev,
    // Contents/Resources in a packaged .app -- see resourceRoot()).
    let artwork = URL(fileURLWithPath: resourceRoot() + "/design/AppIcon.png")
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
    if let hammer = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: AppInfo.displayName)?
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
    // The held-Caps which-key legend reads the live catalog each time it shows.
    CapsHyperTap.shared.legendProvider = {
        let raw = (try? Native.shared.lua.call("platform.registry", "hyperLegend"))?.first as? [Any] ?? []
        return raw.compactMap { item -> HyperHintPanel.Row? in
            guard let d = item as? [String: Any],
                  let key = d["key"] as? String,
                  let label = d["label"] as? String else { return nil }
            return HyperHintPanel.Row(key: key, label: label, chord: (d["chord"] as? Bool) ?? false)
        }
    }
    CapsHyperPreference.apply()   // start the Caps->Hyper tap if opted in

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
        print("[hammerdeck] locale=\(LocaleResolver.current)")
        for f in store.features {
            print("\(f.id) \"\(f.name)\" [\(f.category)/\(f.kind)] enabled=\(f.enabled) trigger=\(f.triggerDesc)")
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

    // First launch: open the Homepage with the Feature Tour so a new user lands
    // on a live preview of "here's what Hammerdeck can do" and adds what they
    // want -- not a bare menubar icon, and not all 19 features pre-enabled. Every
    // later launch stays quiet (it's "Home…" in the menu) -- a login-item menubar
    // app must not throw a window up on every boot.
    if isFirstRun {
        homepageWindow.presentTour()
    }

    // Debug-only: a file-polled Lua control channel for visual verification
    // (off unless HAMMERDECK_CONTROL_DIR is set; the launcher sets it).
    #if DEBUG
    DebugControl.openSettings = { id in
        homepageWindow.show(.settings)
        if let id { store.selectedFeatureId = id }
    }
    DebugControl.openHome = { dest in
        homepageWindow.show(dest.flatMap(HomeDestination.init(rawValue:)) ?? .home)
    }
    DebugControl.presentTour = { homepageWindow.presentTour() }
    #endif
    DebugControl.startIfRequested(lua)

    // Clean teardown on quit: stop every feature (unbind hotkeys, watchers,
    // timers, panels) before the process exits, instead of relying on the OS to
    // reclaim native resources implicitly.
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            // Restore plain Caps Lock on a clean quit (clears the hidutil remap);
            // otherwise Caps would stay a dead F18 key until the next launch.
            CapsHyperTap.shared.disable()
            _ = try? Native.shared.lua.call("platform.registry", "stopAll")
        }
    }

    app.run()
}
