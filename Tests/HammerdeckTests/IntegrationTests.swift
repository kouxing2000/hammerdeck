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

    // The number of features autodiscovery SHOULD find on disk, derived the
    // same way Native.discoverFeatures does (a `<name>/init.lua` subdir or a
    // flat `<name>.lua` file). Counting from the filesystem instead of a
    // hardcoded literal keeps the catalog-completeness assertions from
    // breaking every time a feature is added or removed.
    static var diskFeatureCount: Int {
        let fm = FileManager.default
        let dir = repoRoot + "/lua/features"
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var names = Set<String>()
        for entry in entries where !entry.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue {
                if fm.fileExists(atPath: (full as NSString).appendingPathComponent("init.lua")) {
                    names.insert(entry)
                }
            } else if entry.hasSuffix(".lua"), entry != "init.lua" {
                names.insert(String(entry.dropLast(4)))
            }
        }
        return names.count
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

    /// The secure RNG seam: native.random_int(min,max) stays inclusive-in-range
    /// across positive, single-value, and zero-straddling (negative) ranges --
    /// the last is the case the modular-space hardening protects against.
    func testSecureRandomIntBounds() {
        XCTAssertEqual(eval("return native.random_int(7, 7)") as? Double, 7,
                       "a single-value range returns exactly that value")
        for (lo, hi) in [(1, 6), (-5, 5), (-100, -90)] {
            for _ in 0..<200 {
                guard let v = eval("return native.random_int(\(lo), \(hi))") as? Double else {
                    return XCTFail("random_int(\(lo),\(hi)) did not return a number")
                }
                XCTAssertTrue(v >= Double(lo) && v <= Double(hi),
                              "random_int(\(lo),\(hi)) = \(v) out of range")
                XCTAssertEqual(v, v.rounded(), "random_int must return an integer")
            }
        }
    }

    /// The bridge reader honors json.lua's `__jsontype` tag, so a value's
    /// array-vs-object shape survives the Lua->Swift hop (decisive for empties).
    func testBridgeHonorsJsonTypeTag() {
        let j = "local j = require('platform.json'); return "
        XCTAssertTrue(eval("\(j) j.asObject({})") is [String: Any],
                      "an empty object-tagged table must read as a dict, not an array")
        XCTAssertTrue(eval("\(j) j.asArray({})") is [Any],
                      "an empty array-tagged table must read as an array")
        XCTAssertTrue(eval("return ({})") is [Any],
                      "an untagged empty table stays an array (historical default)")
        let obj = eval("\(j) j.asObject({ a = 1 })") as? [String: Any]
        XCTAssertEqual(obj?["a"] as? Double, 1, "a populated object still reads its keys")
        XCTAssertTrue(eval("return ({ name = 'x' })") is [String: Any],
                      "an untagged string-keyed map still reads as a dict")
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

    /// Pump the event queue until `cond` holds or `timeout` elapses. Returns
    /// whether it became true. Condition-based waiting beats a fixed sleep for
    /// async panel/timer work -- a constant delay races under machine load.
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 3.0, _ cond: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if cond() { return true }
            pumpAppEvents(0.02)
        }
        return cond()
    }

    /// Tests that show real on-screen panels or synthesize system-wide
    /// keystrokes are disruptive while someone is using the machine -- dialogs
    /// flash, and synthesized text lands in whatever app is focused. They run
    /// only on explicit opt-in so a routine `swift test` stays quiet:
    ///   HAMMERDECK_UI_TESTS=1 swift test
    private func requireUITests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAMMERDECK_UI_TESTS"] == "1",
            "UI/synthesis test -- set HAMMERDECK_UI_TESTS=1 to run "
            + "(shows real panels / posts real keystrokes)")
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

    /// Whether the console session is behind the lock screen. AX window
    /// listing and focused-window state are meaningless there (loginwindow
    /// owns the session, lists nothing, and reports zero-size frames) --
    /// environment-dependent tests skip instead of failing red when
    /// `swift test` runs while the screen is locked.
    private func sessionLocked() -> Bool {
        let d = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (d?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    // MARK: - Tier 1: real bridge, no special permissions

    func testBootRegistersWholeCatalog() {
        let expected = TestHost.diskFeatureCount
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double, Double(expected),
                       "disk discovery should find every feature folder (\(expected) on disk)")
        host.store.refresh()
        XCTAssertGreaterThanOrEqual(host.store.features.count, expected)
        XCTAssertTrue(host.store.features.contains { $0.id == "window_switcher" })

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
        host.store.setEnabled("plain_paste", true)
        XCTAssertEqual(eval("return require('platform.registry').isEnabled('plain_paste')") as? Bool,
                       true)
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the Carbon hotkey should be registered")
        host.store.setEnabled("plain_paste", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0, "disable must leak nothing")
    }

    func testTriggerRebindEvalChunksAndConflict() {
        host.store.setEnabled("plain_paste", true)
        host.store.setEnabled("locate_pointer", true)

        // Conflict: locate_pointer owns cmd+alt+ctrl+m.
        let conflict = host.store.setTrigger(
            "plain_paste", "main",
            TriggerSpec(type: "hotkey", mods: ["cmd", "alt", "ctrl"], key: "m"))
        XCTAssertNotNil(conflict, "rebinding onto a taken hotkey must be refused")

        // Success: a free combo persists encoded under the per-action key.
        let err = host.store.setTrigger(
            "plain_paste", "main",
            TriggerSpec(type: "hotkey", mods: ["ctrl", "shift"], key: "9"))
        XCTAssertNil(err)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hammerdeck.trigger.plain_paste.main"),
                       "hotkey|ctrl,shift|9")

        host.store.clearTrigger("plain_paste", "main")
        XCTAssertNil(UserDefaults.standard.object(forKey: "hammerdeck.trigger.plain_paste.main"))

        host.store.setEnabled("plain_paste", false)
        host.store.setEnabled("locate_pointer", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0)
    }

    // The Automation Timeline's data: a service's self-reported schedule
    // descriptor and the lone action-level schedule trigger, end to end through
    // the REAL bridge into the SettingsStore models the SwiftUI view renders.
    func testServiceScheduleDescriptorFlowsThroughBridge() {
        UserDefaults.standard.set("23:30", forKey: "hammerdeck.opt.sleep_schedule.sleepAt")
        UserDefaults.standard.set(10.0, forKey: "hammerdeck.opt.sleep_schedule.warn1Min")
        defer {
            UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.sleep_schedule.sleepAt")
            UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.sleep_schedule.warn1Min")
        }
        host.store.refresh()

        let sleep = host.store.features.first { $0.id == "sleep_schedule" }
        XCTAssertEqual(sleep?.schedule.count, 4, "sleep_schedule reports 4 schedule entries")
        let force = sleep?.schedule.first { $0.optionKey == "sleepAt" }
        XCTAssertEqual(force?.at, "23:30")
        XCTAssertEqual(force?.minutesOfDay, 23 * 60 + 30, "minutesOfDay parses HH:MM")
        let warn = sleep?.schedule.first { $0.label == "First warning" }
        XCTAssertEqual(warn?.at, "23:20", "warning derived as sleepAt - warn1Min")
        XCTAssertNil(warn?.optionKey, "a derived warning is advisory (read-only)")

        // bing_daily ships the only action-level schedule trigger, plus an event
        // descriptor entry -- both feed the Timeline.
        let bing = host.store.features.first { $0.id == "bing_daily" }
        XCTAssertTrue(bing?.actions.contains { $0.trigger?.type == "schedule" } ?? false,
                      "bing_daily.refresh carries a schedule trigger")
        XCTAssertTrue(bing?.schedule.contains { $0.kind == "event" } ?? false,
                      "bing_daily reports its screenChanged event")
    }

    // Editing a service schedule from the Timeline writes the named option (the
    // same path Settings uses); the descriptor then reports the new interval.
    func testEditServiceScheduleViaOptionRoundTrips() {
        host.store.refresh()
        guard let br = host.store.features.first(where: { $0.id == "break_reminder" }),
              let workOpt = br.options.first(where: { $0.key == "workMin" }) else {
            return XCTFail("break_reminder/workMin missing")
        }
        host.store.setOptionValue("break_reminder", workOpt, 45)
        defer { UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.break_reminder.workMin") }
        host.store.refresh()
        let entry = host.store.features.first { $0.id == "break_reminder" }?
            .schedule.first { $0.kind == "everyMin" }
        XCTAssertEqual(entry?.everyMin, 45, "the recurring break tracks the edited workMin")
    }

    // The Feature Gallery's "has conflict" filter / per-card badge: a bound
    // hotkey that collides with a macOS system shortcut is allowed (advisory,
    // not blocked) but must surface in conflictedFeatureIds. Clearing it back to
    // the feature's clean default drops it again.
    func testGalleryConflictScanFlagsSystemCollision() {
        host.store.setEnabled("plain_paste", true)
        defer { host.store.setEnabled("plain_paste", false) }

        let err = host.store.setTrigger("plain_paste", "main",
            TriggerSpec(type: "hotkey", mods: ["cmd"], key: "space"))   // Spotlight
        XCTAssertNil(err, "a system-shortcut collision is advisory, not refused")
        XCTAssertTrue(host.store.conflictedFeatureIds().contains("plain_paste"),
                      "a soft system collision flags the feature as conflicted")

        // Reverting to the (clean) default ctrl+cmd+v drops it from the set.
        host.store.clearTrigger("plain_paste", "main")
        XCTAssertFalse(host.store.conflictedFeatureIds().contains("plain_paste"),
                       "clearing the override leaves no conflict")
    }

    // The card data the Gallery renders, end to end through the real bridge:
    // category + one-line description, the service/action distinction (a pure
    // service has no actions, so its card shows "always on"), and the
    // store-level selection the card click deep-links into the Settings detail.
    func testGalleryCardDataAndDeepLink() {
        host.store.refresh()

        let palette = host.store.features.first { $0.id == "command_palette" }
        XCTAssertEqual(palette?.category, "platform")
        XCTAssertFalse(palette?.description.isEmpty ?? true,
                       "a card needs the one-line description")

        let off = host.store.features.first { $0.id == "display_off" }
        XCTAssertEqual(off?.kind, "service")
        XCTAssertTrue(off?.actions.isEmpty ?? false,
                      "a pure service has no actions -> card shows 'always on'")

        // Deep-link contract: the Gallery sets the focused feature on the store,
        // then jumps to the embedded Settings tab (SettingsPane binds its list
        // selection to this).
        host.store.selectedFeatureId = "locate_pointer"
        XCTAssertEqual(host.store.selectedFeatureId, "locate_pointer")
    }

    // The Homepage Dashboard's "Right now" card: DashboardView.upcoming aggregates
    // daily-time fires (service `at` descriptors + action schedule triggers) from
    // ENABLED, non-failed features, sorted by time-until-next-fire (wrapping past
    // midnight) and capped. A pure function over describe()-shaped data, so it is
    // tested deterministically with synthetic FeatureInfo (independent of whether
    // a given service can start headless).
    func testDashboardUpcomingAggregation() {
        func feat(_ id: String, enabled: Bool, failed: Bool = false,
                  at: [(String, String)] = [],
                  actionAt: [(String, String, String)] = []) -> FeatureInfo {
            let sched: [[String: Any]] = at.map { ["label": $0.0, "kind": "at", "at": $0.1] }
            let acts: [[String: Any]] = actionAt.map {
                ["id": $0.0, "label": $0.1, "trigger": ["type": "schedule", "at": $0.2]]
            }
            return FeatureInfo(["id": id, "name": id, "enabled": enabled,
                                "failed": failed, "schedule": sched, "actions": acts])!
        }

        let feats = [
            feat("sleep", enabled: true, at: [("Force system sleep", "23:30")]),
            feat("bing", enabled: true, actionAt: [("refresh", "Refresh", "06:00")]),
            feat("off", enabled: false, at: [("never", "01:00")]),       // disabled -> excluded
            feat("broken", enabled: true, failed: true, at: [("x", "07:00")]),  // failed -> excluded
        ]

        // now = 08:00. sleep 23:30 -> 930 min away; bing 06:00 -> wraps to 1320.
        let items = DashboardView.upcoming(feats, now: 8 * 60, limit: 8)
        XCTAssertEqual(items.count, 2, "only enabled, non-failed features contribute")
        XCTAssertNil(items.first { $0.id.hasPrefix("off") || $0.id.hasPrefix("broken") })
        XCTAssertEqual(items.first?.minutes, 23 * 60 + 30, "soonest-next-fire sorts first")
        XCTAssertEqual(items.first?.untilNext, 930)
        XCTAssertEqual(items.map { $0.untilNext }, items.map { $0.untilNext }.sorted())

        // The cap truncates, keeping the soonest.
        XCTAssertEqual(DashboardView.upcoming(feats, now: 8 * 60, limit: 1).count, 1)

        // Relative-time formatting (the card's trailing label).
        XCTAssertEqual(DashboardView.relative(0), "now")
        XCTAssertEqual(DashboardView.relative(45), "in 45 min")
        XCTAssertEqual(DashboardView.relative(15 * 60 + 30), "in 15h 30m")
    }

    // The Dashboard's "Tip of the day": DashboardView.tipFeature picks one
    // feature deterministically per day -- stable within a day, rotating across
    // days, never a failed plugin, preferring DISABLED features (rediscovery).
    func testDashboardTipOfDayPick() {
        func feat(_ id: String, enabled: Bool, failed: Bool = false) -> FeatureInfo {
            FeatureInfo(["id": id, "name": id, "enabled": enabled, "failed": failed])!
        }
        let feats = [
            feat("alpha", enabled: false),
            feat("bravo", enabled: true),
            feat("charlie", enabled: false),
            feat("delta", enabled: true, failed: true),   // failed -> never tipped
        ]

        // Prefers disabled (alpha, charlie -- sorted by id); deterministic per day.
        let d0 = DashboardView.tipFeature(feats, dayOfYear: 0)
        XCTAssertEqual(d0?.id, "alpha")
        XCTAssertEqual(DashboardView.tipFeature(feats, dayOfYear: 1)?.id, "charlie")
        XCTAssertEqual(DashboardView.tipFeature(feats, dayOfYear: 2)?.id, "alpha", "wraps over the pool")
        // Same day -> same pick (stable within a day).
        XCTAssertEqual(DashboardView.tipFeature(feats, dayOfYear: 0)?.id, d0?.id)
        XCTAssertNotEqual(d0?.id, "delta", "a failed plugin is never tipped")

        // Once everything (non-failed) is enabled, the pool falls back to all of
        // them rather than going empty.
        let allOn = [feat("alpha", enabled: true), feat("bravo", enabled: true)]
        XCTAssertNotNil(DashboardView.tipFeature(allOn, dayOfYear: 0))

        // No usable features -> no tip (the card hides).
        XCTAssertNil(DashboardView.tipFeature([feat("x", enabled: true, failed: true)], dayOfYear: 0))
    }

    // The Homepage greets the user only on the very first launch, and never when
    // first-run is suppressed (CI / smoke tests). Pure decision, so it's checked
    // without booting the GUI (the actual show() runs inside hammerdeckMain).
    func testFirstRunGreetsWithHomepage() {
        XCTAssertTrue(shouldGreetWithHomepage(noFirstRunEnv: nil, firstRunDone: false),
                      "fresh install -> show the Homepage")
        XCTAssertFalse(shouldGreetWithHomepage(noFirstRunEnv: nil, firstRunDone: true),
                       "later launches stay quiet")
        XCTAssertFalse(shouldGreetWithHomepage(noFirstRunEnv: "1", firstRunDone: false),
                       "HAMMERDECK_NO_FIRSTRUN suppresses the greeting (CI / smoke)")
    }

    func testMenuQuickTriggerRunsTheAction() {
        // The menubar quick-trigger path: store.runAction -> registry.runAction
        // -> the feature's run(ctx), end to end on the real bridge.
        host.store.setEnabled("plain_paste", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.plain_paste.mode")
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.setEnabled("plain_paste", false)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        pb.clearContents()
        pb.setString("   from the menu   ", forType: .string)
        host.store.runAction("plain_paste", "main")
        XCTAssertEqual(pb.string(forType: .string), "from the menu",
                       "the quick trigger should run the real action")
        // The action always pastes after 0.5s; the defer's setEnabled(false)
        // tears the pending timer down long before it could fire.
    }

    // MARK: - Real native panels, driven in-process (no global hotkey)

    /// Probe: can borderless panels actually take key focus in THIS launch
    /// context? Some headless / CI launches order panels front but never confer
    /// key focus. Like `canDeliverSynthesizedHotkeys`, this lets the *focus*
    /// claim skip while the structural (visible/hidden) assertions still run.
    private func canPanelsBecomeKey() -> Bool {
        eval("""
        _G.itKeyProbe = require('platform.adapter').chooser({ onSelect = function() end })
        _G.itKeyProbe.setChoices({ { text = "probe" } })
        _G.itKeyProbe.setPlaceholder("itKeyProbe")
        _G.itKeyProbe.show()
        return true
        """)
        pumpAppEvents(0.2)
        let key = Native.shared.visibleChoosers()
            .first { $0.placeholder == "itKeyProbe" }?.isKey ?? false
        eval("_G.itKeyProbe.stop(); _G.itKeyProbe = nil; return true")
        pumpAppEvents(0.1)
        return key
    }

    /// The command_palette focus-handoff: open the palette (via the runAction
    /// path -- no global hotkey, so no Accessibility needed), pick a command
    /// that opens its OWN chooser, and assert the palette yields and the new
    /// chooser comes up + takes focus. This is the bit neither test layer could
    /// see before. Drives + inspects the REAL NSPanels via Native introspection.
    func testCommandPaletteFocusHandoff() throws {
        try requireUITests()
        // A throwaway feature whose action just opens a chooser -- deterministic,
        // unlike window_switcher (which needs Accessibility + real windows).
        eval("""
        package.loaded["features._it_picker"] = {
          api = 1, id = "it_picker", name = "IT Picker",
          action = function(ctx)
            local ch = ctx.chooser({ onSelect = function() end })
            ch.setPlaceholder("IT Picker Open")
            ch.setChoices({ { text = "alpha" }, { text = "beta" } })
            ch.show()
          end,
        }
        require('platform.registry').load('features._it_picker')
        return true
        """)
        defer {
            host.store.setEnabled("it_picker", false)
            host.store.setEnabled("command_palette", false)
            eval("require('platform.registry').unregister('it_picker'); return true")
            pumpAppEvents(0.1)
            XCTAssertEqual(registryNum("liveHandleCount()"), 0, "panel test must leak nothing")
        }

        host.store.setEnabled("it_picker", true)
        host.store.setEnabled("command_palette", true)

        // Open the palette in-process (same path as a menubar quick trigger).
        host.store.runAction("command_palette", "main")
        waitUntil { Native.shared.visibleChoosers().contains {
            $0.placeholder == "Run a command" && $0.entries.contains("IT Picker") } }

        let palettes = Native.shared.visibleChoosers().filter { $0.placeholder == "Run a command" }
        XCTAssertEqual(palettes.count, 1, "the palette opened exactly one chooser")
        guard let palette = palettes.first else { return }
        XCTAssertTrue(palette.entries.contains("IT Picker"),
                      "palette lists the enabled feature's command; got \(palette.entries)")

        // Pick the it_picker row as the user would.
        guard let idx = palette.entries.firstIndex(of: "IT Picker") else {
            return XCTFail("IT Picker row not found")
        }
        Native.shared.selectChooserRow(id: palette.id, row: idx + 1)

        // The palette dismisses synchronously; the command runs on the next tick
        // (ctx.afterSeconds(0, ...)) so the two panels never fight for focus.
        func paletteVisible() -> Bool {
            Native.shared.chooserSnapshots().first { $0.id == palette.id }?.visible ?? false
        }
        XCTAssertFalse(paletteVisible(), "selecting a command dismisses the palette immediately")

        // The deferred command opens it_picker's own chooser on the next tick.
        waitUntil { Native.shared.visibleChoosers().contains {
            $0.placeholder == "IT Picker Open" && $0.rowCount == 2 } }

        let opened = Native.shared.visibleChoosers().filter { $0.placeholder == "IT Picker Open" }
        XCTAssertEqual(opened.count, 1, "the selected command opened its own chooser")
        XCTAssertEqual(opened.first?.rowCount, 2, "with its own rows")
        XCTAssertNotEqual(opened.first?.id, palette.id, "a distinct panel from the palette")
        XCTAssertFalse(paletteVisible(), "the palette stays gone after the hand-off")

        // Focus actually moved -- the contention bug this whole exercise targets.
        if canPanelsBecomeKey() {
            XCTAssertTrue(opened.first?.isKey ?? false,
                          "the handed-off chooser took key focus (no focus contention)")
        } else {
            print("[it] skipping key-focus assertion: panels cannot become key in this context")
        }

        // Order the handed-off chooser out so it does not linger between tests.
        if let q = opened.first { Native.shared.selectChooserRow(id: q.id, row: 0) }
        pumpAppEvents(0.1)
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
        host.store.setEnabled("display_off", true)
        host.store.reload()
        XCTAssertEqual(eval("return require('platform.registry').isEnabled('display_off')") as? Bool,
                       true, "enabled-state must survive a reload")
        XCTAssertEqual(eval("return #require('platform.registry').all()") as? Double,
                       Double(TestHost.diskFeatureCount))
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the enabled service must be re-bound after reload")
        host.store.setEnabled("display_off", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0)
    }

    func testBannerPanelLifecycle() throws {
        try requireUITests()
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

    func testUsageWidgetPanelLifecycle() throws {
        try requireUITests()
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
        host.store.setEnabled("plain_paste", true)
        // Rebind onto a chord: ChordCenter registers the prefix via the real
        // Carbon HotkeyCenter, so a live handle must exist.
        let err = host.store.setTrigger(
            "plain_paste", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b"]))
        XCTAssertNil(err, "binding a chord should succeed")
        XCTAssertGreaterThanOrEqual(registryNum("liveHandleCount()") ?? 0, 1,
                                    "the chord's prefix hotkey should be registered")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hammerdeck.trigger.plain_paste.main"),
                       "chord|cmd,shift|a|b", "the chord override persisted encoded")

        host.store.clearTrigger("plain_paste", "main")   // back to its default hotkey
        host.store.setEnabled("plain_paste", false)
        XCTAssertEqual(registryNum("liveHandleCount()"), 0, "disable must leak nothing")
    }

    func testRealWindowListingViaAX() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
            "needs Accessibility (grant it to the terminal running `swift test`)")
        try XCTSkipUnless(!sessionLocked(),
            "screen is locked; AX lists no windows behind the lock")

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
        try requireUITests()
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
        // nil (headless session) -- never a crash. Skipped behind the lock
        // screen, where loginwindow reports a zero-size focused window.
        if AXIsProcessTrusted(), !sessionLocked(),
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

    /// Real Chrome-DB favicon extraction (the donor's mechanism, in Swift):
    /// skips when no Chrome profile exists; when a domain is saved, the file
    /// must be a verified PNG.
    func testChromeFaviconExtraction() throws {
        let dbPath = NSHomeDirectory()
            + "/Library/Application Support/Google/Chrome/Default/Favicons"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dbPath),
                          "no Chrome profile on this machine")
        let tmp = NSTemporaryDirectory() + "hammerdeck-it-favicons-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        eval("""
        _G.itFav = nil
        require('platform.adapter').extractFavicons('\(tmp)',
            { 'github.com', 'no-such-domain-42.test' },
            function(saved) _G.itFav = #saved end)
        return true
        """)
        spinRunLoop(3.0)   // background copy + query, callback on main
        let n = eval("return _G.itFav") as? Double
        XCTAssertNotNil(n, "the extraction callback must fire")
        if (n ?? 0) >= 1 {
            let data = FileManager.default.contents(atPath: tmp + "/github.com.png")
            XCTAssertEqual(data?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]),
                           "an extracted favicon is a verified PNG")
        }
        eval("_G.itFav = nil; return true")
    }

    func testLogFileWrittenAndPruned() {
        // Always-on file logging: a ctx.log line lands in today's file.
        eval("require('platform.adapter').log('integration log probe'); return true")
        let day = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
            .string(from: Date())
        let todayLog = Native.logsDir.appendingPathComponent(day + ".log").path
        let content = (try? String(contentsOfFile: todayLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("integration log probe"),
                      "log lines must reach the daily file, not just stdout")

        // Retention: ancient files are pruned, recent ones kept.
        let fm = FileManager.default
        let ancient = Native.logsDir.appendingPathComponent("2020-01-01.log")
        fm.createFile(atPath: ancient.path, contents: Data("old".utf8))
        Native.pruneOldLogs(keep: 14)
        XCTAssertFalse(fm.fileExists(atPath: ancient.path) &&
                       ((try? fm.contentsOfDirectory(atPath: Native.logsDir.path))?
                           .filter { $0.hasSuffix(".log") }.count ?? 0) > 14,
                       "files beyond the keep window are pruned")
        try? fm.removeItem(at: ancient)   // tidy in case the dir held < keep files
        XCTAssertTrue(fm.fileExists(atPath: todayLog), "today's log always survives")
    }

    // MARK: - Tier 2: end-to-end hotkey via synthesized CGEvents (gated)

    func testGlobalHotkeySynthesis() throws {
        try requireUITests()
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        host.store.setEnabled("plain_paste", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.plain_paste.mode")
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.setEnabled("plain_paste", false)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        pb.clearContents()
        pb.setString("  padded text  ", forType: .string)

        // ctrl+cmd+v: plain_paste's default trigger. Mirror real input:
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

        // Slice-pump until the action lands, then DISARM at once: the action
        // always schedules a cmd+v at +0.5s, which must never fire into the
        // user's frontmost app during a test run.
        var landed = false
        for _ in 0..<20 {
            pumpAppEvents(0.05)
            if pb.string(forType: .string) == "padded text" { landed = true; break }
        }
        host.store.setEnabled("plain_paste", false)   // cancels the pending paste
        XCTAssertTrue(landed,
                      "the synthesized hotkey should run the real action end to end")
    }

    /// The full chord path: a synthesized prefix hotkey arms ChordCenter, which
    /// transiently registers the follow key; a second synthesized press of that
    /// bare key fires the action. Proves the modal register/unregister dance
    /// works against the real Carbon event queue -- not just the Lua wiring.
    func testChordHotkeySynthesis() throws {
        try requireUITests()
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        host.store.setEnabled("plain_paste", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.plain_paste.mode")
        // Bind the action to a chord: ⌘⇧A, then B.
        let bindErr = host.store.setTrigger(
            "plain_paste", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b"]))
        XCTAssertNil(bindErr)

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.clearTrigger("plain_paste", "main")
            host.store.setEnabled("plain_paste", false)
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
        // Land-then-disarm (see testGlobalHotkeySynthesis).
        var landed = false
        for _ in 0..<16 {
            pumpAppEvents(0.05)
            if pb.string(forType: .string) == "padded text" { landed = true; break }
        }
        host.store.setEnabled("plain_paste", false)
        XCTAssertTrue(landed,
                      "the synthesized chord (⌘⇧A then B) should run the action end to end")
    }
}
