import XCTest
import AppKit
import Carbon.HIToolbox
@testable import HammerdeckKit

// Integration tests against the REAL stack -- no fake adapter. The Lua
// platform boots in-process on the actual Native bridge, so these cover the
// layer the headless Lua suite (test/run.lua) cannot: the Lua<->Swift value
// crossing, UserDefaults persistence, Carbon hotkey registration, real
// timers on the run loop, the filesystem discovery scan, and the eval chunks
// the Settings UI emits.
//
// Tier 1 runs everywhere (`swift test`). Tier 2 (testGlobalHotkeySynthesis)
// posts real CGEvents, which macOS only allows for Accessibility-trusted
// processes -- it auto-skips unless the terminal running the tests has been
// granted Accessibility.

/// One shared boot per process: Native bindings and the Lua state are
/// process-global singletons, so the platform boots exactly once.
@MainActor
final class TestHost {
    static let shared = TestHost()
    let lua: LuaState
    let store: SettingsStore

    private init() {
        setenv("HAMMERDECK_NO_FIRSTRUN", "1", 1)

        // Isolation: `swift test` runs in its own defaults domain (the test
        // runner's, not the Hammerdeck app's), but clear any hammerdeck.*
        // leftovers from previous runs so every run starts from scratch.
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("hammerdeck.") {
            d.removeObject(forKey: key)
        }

        // Panels need the app object; Carbon's event dispatcher (hotkey
        // delivery) needs the app to have finished launching -- `swift run`
        // gets that from app.run(), tests must do it explicitly.
        let app = NSApplication.shared
        app.finishLaunching()
        lua = LuaState()
        Native.shared.attach(lua)
        Native.shared.installBindings()
        try! bootLua(lua, luaDir: TestHost.repoRoot + "/lua")
        store = SettingsStore(lua: lua)
    }

    static var repoRoot: String {
        URL(fileURLWithPath: #filePath)      // .../Tests/HammerdeckTests/IntegrationTests.swift
            .deletingLastPathComponent()      // .../Tests/HammerdeckTests
            .deletingLastPathComponent()      // .../Tests
            .deletingLastPathComponent()      // repo root
            .path
    }
}

@MainActor
final class IntegrationTests: XCTestCase {
    var host: TestHost { TestHost.shared }

    @discardableResult
    private func eval(_ code: String) -> Any? {
        do { return try host.lua.eval(code) } catch {
            XCTFail("eval failed: \(error) -- \(code)")
            return nil
        }
    }

    private func registryNum(_ expr: String) -> Double? {
        eval("return require('platform.registry').\(expr)") as? Double
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Pump the real application event queue (what app.run() does) -- plain
    /// RunLoop spinning does not drain the Carbon event queue that delivers
    /// RegisterEventHotKey presses.
    private func pumpAppEvents(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            if let e = NSApp.nextEvent(matching: .any,
                                       until: Date(timeIntervalSinceNow: 0.05),
                                       inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    /// Whether synthesized CGEvents actually reach our Carbon hotkeys in THIS
    /// launch context. `AXIsProcessTrusted()` is necessary but not sufficient --
    /// it can report true while event posting silently fails (some headless /
    /// CI / remote-session launches of `swift test`). The synthesis tests gate
    /// on this probe instead: register a temp hotkey on an unlikely key, post
    /// it, and report whether it fired -- so an incapable environment SKIPS
    /// rather than producing a misleading red.
    private func canDeliverSynthesizedHotkeys() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var fired = false
        guard let unbind = HotkeyCenter.shared.bind(mods: [], key: "f19", handler: { fired = true })
        else { return false }
        defer { unbind() }
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F19), keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F19), keyDown: false)?
            .post(tap: .cghidEventTap)
        pumpAppEvents(0.3)
        return fired
    }

    // MARK: - Tier 1: real bridge, no special permissions

    func testBootRegistersWholeCatalog() {
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double, 14,
                       "disk discovery should find all 14 features")
        host.store.refresh()
        XCTAssertGreaterThanOrEqual(host.store.features.count, 14)
        XCTAssertTrue(host.store.features.contains { $0.id == "window_jump" })

        // Multi-action shape survives the any() bridge crossing.
        let countDown = host.store.features.first { $0.id == "count_down" }
        XCTAssertEqual(countDown?.actions.count, 2)
        XCTAssertEqual(countDown?.actions.first?.id, "start")
        XCTAssertNotNil(countDown?.actions.first?.defaultTrigger)
    }

    func testSettingsBridgeRoundTrip() {
        eval("require('platform.adapter').setSetting('hammerdeck.it.num', 42); return true")
        XCTAssertEqual(UserDefaults.standard.double(forKey: "hammerdeck.it.num"), 42)

        UserDefaults.standard.set("hello", forKey: "hammerdeck.it.str")
        XCTAssertEqual(eval("return require('platform.adapter').getSetting('hammerdeck.it.str')") as? String,
                       "hello")

        // CFBoolean vs NSNumber disambiguation both directions.
        eval("require('platform.adapter').setSetting('hammerdeck.it.flag', true); return true")
        XCTAssertEqual(eval("return require('platform.adapter').getSetting('hammerdeck.it.flag')") as? Bool,
                       true)

        // nil removes.
        eval("require('platform.adapter').setSetting('hammerdeck.it.num', nil); return true")
        XCTAssertNil(UserDefaults.standard.object(forKey: "hammerdeck.it.num"))

        for k in ["hammerdeck.it.str", "hammerdeck.it.flag"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    func testEnableBindsARealCarbonHotkey() {
        host.store.setEnabled("clipboard_clean", true)
        XCTAssertEqual(eval("return require('platform.registry').isEnabled('clipboard_clean')") as? Bool,
                       true)
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the Carbon hotkey should be registered")
        host.store.setEnabled("clipboard_clean", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0, "disable must leak nothing")
    }

    func testTriggerRebindEvalChunksAndConflict() {
        host.store.setEnabled("clipboard_clean", true)
        host.store.setEnabled("mouse_circle", true)

        // Conflict: mouse_circle owns cmd+alt+ctrl+m.
        let conflict = host.store.setTrigger(
            "clipboard_clean", "main",
            TriggerSpec(type: "hotkey", mods: ["cmd", "alt", "ctrl"], key: "m"))
        XCTAssertNotNil(conflict, "rebinding onto a taken hotkey must be refused")

        // Success: a free combo persists encoded under the per-action key.
        let err = host.store.setTrigger(
            "clipboard_clean", "main",
            TriggerSpec(type: "hotkey", mods: ["ctrl", "shift"], key: "9"))
        XCTAssertNil(err)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hammerdeck.trigger.clipboard_clean.main"),
                       "hotkey|ctrl,shift|9")

        host.store.clearTrigger("clipboard_clean", "main")
        XCTAssertNil(UserDefaults.standard.object(forKey: "hammerdeck.trigger.clipboard_clean.main"))

        host.store.setEnabled("clipboard_clean", false)
        host.store.setEnabled("mouse_circle", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0)
    }

    func testPasteboardBridge() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        eval("require('platform.adapter').pasteboardWrite('hammerdeck-it'); return true")
        XCTAssertEqual(pb.string(forType: .string), "hammerdeck-it")

        pb.clearContents()
        pb.setString("  abc  ", forType: .string)
        XCTAssertEqual(eval("return require('platform.adapter').pasteboardRead()") as? String, "  abc  ")
    }

    func testTimerFiresOnTheRealRunLoop() {
        eval("""
        _G.itTimerFired = false
        require('platform.adapter').afterSeconds(0.05, function() _G.itTimerFired = true end)
        return true
        """)
        spinRunLoop(0.3)
        XCTAssertEqual(eval("return _G.itTimerFired") as? Bool, true)
    }

    func testDiscoveryScansTheRealFilesystem() throws {
        let tmp = NSTemporaryDirectory() + "hammerdeck-it-\(getpid())"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmp + "/foo", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmp + "/not_a_feature", withIntermediateDirectories: true)
        try "return {}".write(toFile: tmp + "/foo/init.lua", atomically: true, encoding: .utf8)
        try "return {}".write(toFile: tmp + "/bar.lua", atomically: true, encoding: .utf8)
        try "junk".write(toFile: tmp + "/junk.txt", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: tmp) }

        let raw = eval("return require('platform.adapter').discoverFeatures('\(tmp)')") as? [Any]
        let names = raw?.compactMap { $0 as? String }.sorted()
        XCTAssertEqual(names, ["bar", "foo"],
                       "dir-with-init.lua and flat .lua count; junk and bare dirs don't")
    }

    func testHotReloadPreservesEnabledState() {
        host.store.setEnabled("idle_dimmer", true)
        host.store.reload()
        XCTAssertEqual(eval("return require('platform.registry').isEnabled('idle_dimmer')") as? Bool,
                       true, "enabled-state must survive a reload")
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double, 14)
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the enabled service must be re-bound after reload")
        host.store.setEnabled("idle_dimmer", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0)
    }

    func testBannerPanelLifecycle() {
        eval("_G.itBanner = require('platform.adapter').banner('integration'); return true")
        eval("_G.itBanner.setText('updated'); _G.itBanner.stop(); _G.itBanner = nil; return true")
        // Reaching here without a crash is the assertion: a real NSPanel was
        // created, mutated, and torn down through the bridge.
    }

    func testDataDirAndAppTrackingBridge() {
        let dir = eval("return require('platform.adapter').dataDir()") as? String
        XCTAssertEqual(dir?.hasSuffix("Application Support/Hammerdeck"), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir ?? "/nonexistent"),
                      "dataDir must create the directory on demand")

        // File helpers round-trip through the adapter's io implementation.
        let tmp = NSTemporaryDirectory() + "hammerdeck-it-files-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        eval("""
        local a = require('platform.adapter')
        assert(a.mkdir('\(tmp)/sub'))
        a.fileAppend('\(tmp)/sub/x.csv', 'header')
        a.fileAppend('\(tmp)/sub/x.csv', 'row,1')
        return a.fileRead('\(tmp)/sub/x.csv')
        """)
        XCTAssertEqual(try? host.lua.eval(
            "return require('platform.adapter').fileRead('\(tmp)/sub/x.csv')") as? String,
            "header\nrow,1\n")

        // App-activation watcher registers + tears down through the real
        // NSWorkspace notification center (no permission needed).
        eval("_G.itAppWatch = require('platform.adapter').onAppActivated(function(_) end); return true")
        eval("_G.itAppWatch.stop(); _G.itAppWatch = nil; return true")

        XCTAssertNotNil(eval("return require('platform.adapter').frontmostApp()"),
                        "some app is always frontmost")
    }

    func testUsageWidgetPanelLifecycle() {
        // A real desktop-level NSPanel is created, fed a full nested data
        // table across the bridge (the any() crossing), updated, and torn
        // down. Reaching the end without a crash is the assertion.
        eval("_G.itWidget = require('platform.adapter').usageWidget(); return true")
        eval("""
        _G.itWidget.setData({
            total = 5400, updated = '12:34', avg = 3600, weekTotal = 12600,
            apps = { { app = 'Code', secs = 3600 }, { app = 'Safari', secs = 1800 } },
            week = {
                { label = 'S', secs = 0, today = false },
                { label = 'M', secs = 7200, today = false },
                { label = 'T', secs = 5400, today = true },
            },
        })
        return true
        """)
        // Empty state renders too (no apps yet).
        eval("_G.itWidget.setData({ total = 0, updated = '00:00', weekTotal = 0, apps = {}, week = {} }); return true")
        eval("_G.itWidget.stop(); _G.itWidget = nil; return true")
    }

    func testChordRegistersARealPrefixHotkey() {
        host.store.setEnabled("clipboard_clean", true)
        // Rebind onto a chord: ChordCenter registers the prefix via the real
        // Carbon HotkeyCenter, so a live handle must exist.
        let err = host.store.setTrigger(
            "clipboard_clean", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b"]))
        XCTAssertNil(err, "binding a chord should succeed")
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the chord's prefix hotkey should be registered")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hammerdeck.trigger.clipboard_clean.main"),
                       "chord|cmd,shift|a|b", "the chord override persisted encoded")

        host.store.clearTrigger("clipboard_clean", "main")   // back to its default hotkey
        host.store.setEnabled("clipboard_clean", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0, "disable must leak nothing")
    }

    func testRealWindowListingViaAX() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
            "needs Accessibility (grant it to the terminal running `swift test`)")

        XCTAssertEqual(eval("return require('platform.adapter').axTrusted()") as? Bool, true)

        let raw = eval("return require('platform.adapter').listWindows()") as? [Any]
        let rows = raw?.compactMap { $0 as? [String: Any] } ?? []
        XCTAssertFalse(rows.isEmpty, "a real desktop session has at least one window")
        for row in rows.prefix(3) {
            XCTAssertNotNil(row["id"] as? Double, "window rows carry an id")
            XCTAssertFalse((row["title"] as? String ?? "").isEmpty, "windows carry a title")
            XCTAssertFalse((row["appName"] as? String ?? "").isEmpty, "windows carry an app name")
        }

        // Focusing the frontmost window (row 1) is a visual no-op but exercises
        // the full AXRaise + activate path against the cached element.
        if let firstId = (rows.first?["id"] as? Double).map(Int.init) {
            XCTAssertEqual(eval("return require('platform.adapter').focusWindow(\(firstId))") as? Bool,
                           true, "focusing a listed window succeeds")
        }
        // A stale/unknown id is refused, not crashed.
        XCTAssertEqual(eval("return require('platform.adapter').focusWindow(999999)") as? Bool, false)
    }

    /// Closed-loop typing synthesis: type_text + key_stroke are posted system-
    /// wide, and our own AskTextPanel (keyable) is frontmost -- so the text we
    /// synthesize lands in OUR field and Enter submits it back through the
    /// bridge. Proves the #3 text_actions seam end to end without touching
    /// any other app.
    func testTypeTextSynthesisIntoOwnPanel() throws {
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized events")

        // activate_app: a bogus name is refused, not crashed (safe everywhere).
        XCTAssertEqual(eval("return require('platform.adapter').activateApp('NoSuchApp-42')") as? Bool,
                       false)

        eval("""
        _G.itTyped = 'pending'
        _G.itPrompt = require('platform.adapter').askText {
            title = 'integration', placeholder = '', default = '',
            onSubmit = function(text) _G.itTyped = text end,
        }
        return true
        """)
        NSApp.activate(ignoringOtherApps: true)
        pumpAppEvents(0.4)   // let the panel become key

        // SAFETY GATE: typed events go to whatever holds keyboard focus
        // SYSTEM-wide. NSApp.keyWindow alone is an in-process notion -- the
        // window server can still be routing keys to another app (it does for
        // a bundle-less test runner, which macOS won't truly activate). Only
        // type when the system agrees we are the active app AND our panel is
        // key; otherwise the text would land in the user's frontmost window.
        guard NSRunningApplication.current.isActive, NSApp.keyWindow is KeyablePanel else {
            eval("_G.itPrompt.stop(); _G.itPrompt = nil; _G.itTyped = nil; return true")
            throw XCTSkip("test runner cannot take system keyboard focus here; "
                + "refusing to type into another app (covered by "
                + "testGlobalHotkeySynthesis's shared posting path)")
        }

        eval("require('platform.adapter').typeText('hammerdeck-42'); return true")
        pumpAppEvents(0.3)
        eval("require('platform.adapter').keyStroke({}, 'return'); return true")
        pumpAppEvents(0.5)

        XCTAssertEqual(eval("return _G.itTyped") as? String, "hammerdeck-42",
                       "synthesized typing should land in our own panel and submit")
        eval("_G.itPrompt.stop(); _G.itPrompt = nil; _G.itTyped = nil; return true")
    }

    /// READ-ONLY pass over the window-frame surface: never sets a frame (that
    /// would rearrange whatever window the user has focused). Geometry sanity:
    /// everything crosses the seam in ONE coordinate system (top-left origin).
    func testWindowFrameSurfaceReadOnly() throws {
        let raw = eval("return require('platform.adapter').screenFrames()") as? [Any]
        let screens = raw?.compactMap { $0 as? [String: Any] } ?? []
        XCTAssertFalse(screens.isEmpty, "at least one screen exists")
        let s0 = screens[0]
        XCTAssertGreaterThan(s0["w"] as? Double ?? 0, 0)
        XCTAssertGreaterThan(s0["h"] as? Double ?? 0, 0)

        let mouse = eval("return require('platform.adapter').mousePosition()") as? [String: Any]
        XCTAssertNotNil(mouse?["x"] as? Double)
        XCTAssertNotNil(mouse?["y"] as? Double)

        // Focused-window read: a table with a coherent screen reference, or
        // nil (headless session) -- never a crash.
        if AXIsProcessTrusted(),
           let f = eval("return require('platform.adapter').focusedWindowFrame()") as? [String: Any] {
            XCTAssertGreaterThan(f["w"] as? Double ?? 0, 0)
            let idx = Int(f["screenIndex"] as? Double ?? 0)
            XCTAssertTrue((1...screens.count).contains(idx),
                          "screenIndex points into screenFrames()")
            XCTAssertNotNil((f["screen"] as? [String: Any])?["w"] as? Double)
        }
    }

    /// The browser-scripting seam is CURATED: a non-whitelisted app name must
    /// be refused at the bridge (a Lua error), never reach a script. No real
    /// browser is scripted in tests (that would launch apps / TCC prompts).
    func testBrowserScriptingWhitelist() {
        let r1 = try? host.lua.eval(
            "return pcall(function() require('platform.adapter').browserListTabs('Evil App', function() end) end)")
        XCTAssertEqual(r1 as? Bool, false, "non-whitelisted app must raise")
        let r2 = try? host.lua.eval(
            "return pcall(function() require('platform.adapter').browserFocusTab('Evil App', 1, 1, function() end) end)")
        XCTAssertEqual(r2 as? Bool, false)
        XCTAssertNil(eval("return require('platform.adapter').browserActiveURL('Evil App')"),
                     "active-url for a non-whitelisted app is nil, not a script run")

        XCTAssertEqual(eval("return require('platform.adapter').isAppRunning('NoSuchApp-77')") as? Bool,
                       false)

        // file: icon tokens resolve from disk; a missing path is nil, not a crash.
        XCTAssertNil(ChooserPanel.icon(for: "file:/nonexistent/icon.png"))
    }

    // MARK: - Tier 2: end-to-end hotkey via synthesized CGEvents (gated)

    func testGlobalHotkeySynthesis() throws {
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        host.store.setEnabled("clipboard_clean", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.clipboard_clean.mode")
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.setEnabled("clipboard_clean", false)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        pb.clearContents()
        pb.setString("  padded text  ", forType: .string)

        // ctrl+cmd+v: clipboard_clean's default trigger. Mirror real input:
        // modifier key-downs first (flagsChanged), then the letter, then the
        // releases -- some hotkey matchers ignore bare flags on a letter event.
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: Int, down: Bool, flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        key(kVK_Control, down: true, flags: [.maskControl])
        key(kVK_Command, down: true, flags: [.maskControl, .maskCommand])
        key(kVK_ANSI_V, down: true, flags: [.maskControl, .maskCommand])
        key(kVK_ANSI_V, down: false, flags: [.maskControl, .maskCommand])
        key(kVK_Command, down: false, flags: [.maskControl])
        key(kVK_Control, down: false, flags: [])

        pumpAppEvents(1.0)
        XCTAssertEqual(pb.string(forType: .string), "padded text",
                       "the synthesized hotkey should run the real action end to end")
    }

    /// The full chord path: a synthesized prefix hotkey arms ChordCenter, which
    /// transiently registers the follow key; a second synthesized press of that
    /// bare key fires the action. Proves the modal register/unregister dance
    /// works against the real Carbon event queue -- not just the Lua wiring.
    func testChordHotkeySynthesis() throws {
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        host.store.setEnabled("clipboard_clean", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.clipboard_clean.mode")
        // Bind the action to a chord: ⌘⇧A, then B.
        let bindErr = host.store.setTrigger(
            "clipboard_clean", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b"]))
        XCTAssertNil(bindErr)

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.clearTrigger("clipboard_clean", "main")
            host.store.setEnabled("clipboard_clean", false)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        pb.clearContents()
        pb.setString("  padded text  ", forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: Int, down: Bool, flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }

        // 1) The prefix ⌘⇧A -- arms the chord and registers the bare follow key.
        key(kVK_Command, down: true, flags: [.maskCommand])
        key(kVK_Shift, down: true, flags: [.maskCommand, .maskShift])
        key(kVK_ANSI_A, down: true, flags: [.maskCommand, .maskShift])
        key(kVK_ANSI_A, down: false, flags: [.maskCommand, .maskShift])
        key(kVK_Shift, down: false, flags: [.maskCommand])
        key(kVK_Command, down: false, flags: [])
        // Let arm() run and register the bare 'b' BEFORE we press it.
        pumpAppEvents(0.4)

        // 2) The follow key B (no modifiers) -- completes the chord.
        key(kVK_ANSI_B, down: true, flags: [])
        key(kVK_ANSI_B, down: false, flags: [])
        pumpAppEvents(0.8)

        XCTAssertEqual(pb.string(forType: .string), "padded text",
                       "the synthesized chord (⌘⇧A then B) should run the action end to end")
    }
}
