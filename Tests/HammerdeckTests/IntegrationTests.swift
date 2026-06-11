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

    // MARK: - Tier 1: real bridge, no special permissions

    func testBootRegistersWholeCatalog() {
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double, 8,
                       "disk discovery should find all 8 features")
        host.store.refresh()
        XCTAssertGreaterThanOrEqual(host.store.features.count, 8)
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
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double, 8)
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

    // MARK: - Tier 2: end-to-end hotkey via synthesized CGEvents (gated)

    func testGlobalHotkeySynthesis() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
            "needs Accessibility (grant it to the terminal running `swift test`) to post CGEvents")

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
}
