import XCTest
import AppKit
import Carbon.HIToolbox
@testable import HammerdeckKit

// Thread-safe holder so a @Sendable completion (fired on a background queue) can
// hand a value back to a test that reads it after `wait(for:)`.
private final class TestIntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    func set(_ v: Int?) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int? { lock.lock(); defer { lock.unlock() }; return value }
}

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
        try! bootLua(lua, luaDir: TestHost.repoRoot + "/app")
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
        let dir = repoRoot + "/app/features"
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
        var names = Set<String>()
        for entry in entries where !entry.hasPrefix(".") {
            let full = (dir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue,
               fm.fileExists(atPath: (full as NSString).appendingPathComponent("lua/init.lua")) {
                names.insert(entry)
            }
        }
        return names.count
    }
}

@MainActor
final class IntegrationTests: XCTestCase {
    var host: TestHost { TestHost.shared }

    /// Force the process-global boot before every test body. Most tests reach
    /// `host` on their own, but the synthesis probe `canDeliverSynthesizedHotkeys`
    /// pumps the app event queue (NSApp.nextEvent) FIRST -- and `NSApp` only
    /// exists once `TestHost.init` has called `NSApplication.shared`. In a full
    /// run some earlier Tier-1 test boots it incidentally; under `--filter` a
    /// synthesis test can run first and crash on a nil NSApp. Booting here makes
    /// every test order-independent.
    override func setUp() async throws { _ = host }

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

    // NOTE: there is deliberately no `spinRunLoop(seconds)` helper any more.
    // Every caller was really waiting for an async callback, and a flat sleep
    // turns that into a race against a budget nobody can pick correctly -- it
    // scales with machine load and with the user's own data (see the Chrome
    // favicon test, which flaked 1-in-3 that way). Use `waitUntil` below. If you
    // genuinely need to let the run loop breathe with no condition to wait on,
    // `pumpAppEvents(_:)` says that plainly.

    /// The locale seam: adapter.locale() (Lua) returns the SAME resolved code as
    /// the Swift LocaleResolver -- the single authority both layers read -- and is
    /// never empty, so i18n catalog lookups never key off "".
    func testLocaleBridgeMatchesResolver() {
        let viaBridge = eval("return require('platform.adapter').locale()") as? String
        XCTAssertEqual(viaBridge, LocaleResolver.current)
        XCTAssertFalse((viaBridge ?? "").isEmpty)
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

    #if DEBUG
    /// A pinned callback ref leaks if any seam binding drops its releaseRef --
    /// the host's most error-prone bug, the reason the bindObserver / fireCallback
    /// helpers exist. on_system_event binds an observer (makeRef) and returns a
    /// resource id whose stop() must release it; binding then stopping N times
    /// must leave the live pinned-ref count exactly where it started. The test
    /// body is synchronous (no run-loop spin), so no async callback fires to
    /// perturb the count mid-test -- it isolates the observer bind/release path.
    func testSystemEventObserverReleasesItsRef() {
        let lua = host.lua
        let baseline = lua.pinnedRefCount
        for _ in 0..<5 {
            guard let id = eval("return native.on_system_event('wake', function() end)") as? Double else {
                return XCTFail("on_system_event did not return a resource id")
            }
            XCTAssertEqual(lua.pinnedRefCount, baseline + 1, "binding an observer pins exactly one ref")
            eval("native.stop(\(Int(id)))")
            XCTAssertEqual(lua.pinnedRefCount, baseline, "stopping the observer must release its ref")
        }
        XCTAssertEqual(lua.pinnedRefCount, baseline,
                       "no pinned callback ref leaks across repeated bind/stop cycles")
    }
    #endif

    /// P11: both keystroke editors (the Settings TriggerEditor and the Shortcut
    /// Map row) build their spec via TriggerSpec.keyish, so the SAME combo
    /// persists identically no matter which surface bound it -- canonical mod
    /// order (⇧⌃⌥⌘), a lowercased key, and a non-empty follows field promoting to
    /// a chord. (They used to order mods oppositely and one skipped lowercasing.)
    func testTriggerSpecKeyishIsCanonical() {
        let hk = TriggerSpec.keyish(mods: ["cmd", "shift"], key: "K", follows: "")
        XCTAssertEqual(hk.type, "hotkey")
        XCTAssertEqual(hk.mods, ["shift", "cmd"], "mods emit in canonical ⇧⌃⌥⌘ order")
        XCTAssertEqual(hk.key, "k", "the key is trimmed + lowercased")
        XCTAssertTrue(hk.follows.isEmpty)

        let chord = TriggerSpec.keyish(mods: ["alt", "ctrl", "cmd"], key: "A", follows: "B, c")
        XCTAssertEqual(chord.type, "chord", "a non-empty follows field promotes to a chord")
        XCTAssertEqual(chord.mods, ["ctrl", "alt", "cmd"], "canonical order regardless of input set")
        XCTAssertEqual(chord.follows, ["b", "c"], "follow keys split on space/comma, lowercased")
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

    /// Bridge-surface completeness: every `native.<fn>` that adapter.lua actually
    /// calls must exist as a function in the `native` table. This is the guard
    /// for the Native.swift -> Native+*.swift split: dropping or mistyping a
    /// binding in any extension's installBindings entry fails HERE, naming the
    /// missing symbol, instead of surfacing as a confusing nil-call deep inside
    /// one feature at runtime. The demanded set is derived from the adapter
    /// source, so it stays correct as the seam grows -- no list to maintain.
    func testNativeSurfaceMatchesAdapterDemand() {
        let adapterPath = TestHost.repoRoot + "/app/platform/lua/adapter.lua"
        guard let raw = try? String(contentsOfFile: adapterPath, encoding: .utf8) else {
            return XCTFail("could not read adapter.lua at \(adapterPath)")
        }
        // Strip Lua line comments first: a `native.*` mention inside a comment
        // (e.g. a doc line or a TODO) is not a real call and must not drive the
        // assertion -- we only want the actual demanded surface.
        let src = raw.replacingOccurrences(of: "--[^\n]*", with: "", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: "native\\.([a-z_]+)")
        var names = Set<String>()
        for m in re.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
            if let r = Range(m.range(at: 1), in: src) { names.insert(String(src[r])) }
        }
        // Sanity: we actually found the surface (a broken regex would pass vacuously).
        XCTAssertGreaterThan(names.count, 60,
                             "expected the full native.* call surface in adapter.lua, found \(names.count)")
        for name in names.sorted() {
            XCTAssertEqual(eval("return type(native.\(name))") as? String, "function",
                           "native.\(name) is called by adapter.lua but is missing from the bridge")
        }
    }

    /// Trigger-glyph rendering exists once per language (KeyGlyphs.swift on the
    /// Swift side, triggers.lua's `glyph` on the Lua side -- the irreducible
    /// cross-language minimum after the Swift copies were merged, REFACTOR #1).
    /// This drives BOTH with the same specs and asserts they agree, so the two
    /// copies can't silently drift (a new named key, a reordered modifier).
    func testGlyphParityAcrossLanguageSeam() {
        // Pin the load-bearing glyph decisions absolutely, not just "both sides
        // agree" -- so a same-direction drift in both copies (e.g. Return back
        // to U+23CE) still fails. Return is U+21A9 (the macOS menu convention),
        // NOT U+23CE, which the HUD panels used to show out of step.
        XCTAssertEqual(KeyGlyphs.glyph("return"), "\u{21A9}")
        XCTAssertEqual(KeyGlyphs.modifiers(["ctrl", "alt", "shift", "cmd"]), "\u{2303}\u{2325}\u{21E7}\u{2318}")

        var specs: [TriggerSpec] = []
        // Every named key, plus a sampling of single chars and passthroughs.
        // Keys are ASCII in practice; the count==1 upcasing branch counts
        // grapheme clusters in Swift vs bytes in Lua, so a multi-byte key would
        // be a latent parity hole -- not exercised here because none can occur.
        for k in ["tab", "return", "enter", "space", "delete", "backspace",
                  "escape", "esc", "left", "right", "up", "down",
                  "a", "Z", "5", "f1", ""] {
            specs.append(TriggerSpec(type: "hotkey", mods: ["cmd"], key: k))
        }
        // Modifier combinations, including the long-form aliases both sides accept.
        for mods in [[], ["cmd"], ["ctrl", "alt", "shift", "cmd"],
                     ["control", "option", "command"], ["shift", "ctrl"]] {
            specs.append(TriggerSpec(type: "hotkey", mods: mods, key: "v"))
        }
        // Chords (incl. an empty follow list), schedules, and events.
        specs.append(TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b", "left"]))
        specs.append(TriggerSpec(type: "chord", mods: ["cmd"], key: "x", follows: []))
        specs.append(TriggerSpec(type: "schedule", everyMin: 180))
        specs.append(TriggerSpec(type: "schedule", at: "07:30"))
        specs.append(TriggerSpec(type: "event", event: "wake"))

        for spec in specs {
            // Drive the Lua side through the typed call seam (marshalled luaArg),
            // which also exercises LuaArg round-tripping into a real Lua table.
            let lua = (try? host.lua.call("platform.triggers", "glyph", [spec.luaArg]).first ?? nil) as? String
            XCTAssertEqual(lua, shortcutGlyph(spec),
                           "glyph drift for \(spec.type)/\(spec.key): Lua=\(lua ?? "nil") Swift=\(shortcutGlyph(spec))")
        }
    }

    /// The typed call seam (LuaState.call): marshalled args reach Lua as real
    /// values (no source-building), results read back, and -- critically for a
    /// C-API bug -- the Lua stack is left exactly as found on every path
    /// (success, multi-return, and error).
    func testTypedCallMarshalsArgsAndBalancesStack() {
        let top0 = host.lua.stackTop

        // Single string result: glyph of a marshalled hotkey spec.
        let g = try? host.lua.call("platform.triggers", "glyph",
            [.table(["type": .string("hotkey"),
                     "mods": .array([.string("cmd"), .string("shift")]),
                     "key": .string("v")])]).first ?? nil
        XCTAssertEqual(g as? String, "⇧⌘V", "marshalled table arg -> glyph")

        // Nested array marshalling (chord follows) survives the crossing.
        let c = try? host.lua.call("platform.triggers", "describe",
            [.table(["type": .string("chord"), "mods": .array([.string("cmd")]),
                     "key": .string("a"), "follows": .array([.string("b"), .string("c")])])]).first ?? nil
        XCTAssertEqual(c as? String, "chord: cmd+a then b c", "nested array (follows) marshals")

        // Multi-return: registry.runAction on an unknown feature returns
        // (false, reason) -- both results come back across the seam.
        let r = (try? host.lua.call("platform.registry", "runAction",
            [.string("no_such_feature"), .string("main")], results: 2)) ?? []
        XCTAssertEqual(r.count, 2, "results:2 yields two slots")
        XCTAssertEqual(r[0] as? Bool, false, "runAction(unknown) returns false")
        XCTAssertEqual(r[1] as? String, "no such feature: no_such_feature", "reason comes back as the 2nd result")

        // A quote in the data is just data now -- it cannot break a chunk (the
        // whole point of marshalling vs string interpolation).
        _ = try? host.lua.call("platform.triggers", "glyph",
            [.table(["type": .string("hotkey"), "mods": .array([]), "key": .string("'")])])

        // An error path (calling a missing function) must still restore the stack.
        XCTAssertThrowsError(try host.lua.call("platform.registry", "no_such_function_xyz"))

        XCTAssertEqual(host.lua.stackTop, top0, "call leaves the Lua stack balanced across all paths")
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

    /// Tests that show real on-screen panels, synthesize system-wide keystrokes,
    /// or touch the login Keychain are disruptive while someone is using the
    /// machine -- dialogs flash, synthesized text lands in whatever app is
    /// focused, and the Keychain can pop a "xctest wants to use the login
    /// keychain" prompt. They run only on explicit opt-in so a routine
    /// `swift test` stays quiet:
    ///   HAMMERDECK_UI_TESTS=1 swift test
    private func requireUITests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HAMMERDECK_UI_TESTS"] == "1",
            "UI/synthesis/Keychain test -- set HAMMERDECK_UI_TESTS=1 to run "
            + "(shows real panels / posts real keystrokes / prompts for Keychain access)")
    }

    /// Whether synthesized CGEvents actually reach our Carbon hotkeys in THIS
    /// launch context. `AXIsProcessTrusted()` is necessary but not sufficient --
    /// it can report true while event posting silently fails (some headless /
    /// CI / remote-session launches of `swift test`). The synthesis tests gate
    /// on this probe instead: register a temp hotkey on an unlikely key, post
    /// it, and report whether it fired -- so an incapable environment SKIPS
    /// rather than producing a misleading red.
    private func canDeliverSynthesizedHotkeys() -> Bool {
        if let known = Self.synthesisCapable { return known }
        let result = probeSynthesisCapability()
        Self.synthesisCapable = result
        return result
    }

    /// Probed at most ONCE per process (see canDeliverSynthesizedHotkeys).
    ///
    /// Caching is not an optimization, it is the correctness fix. Three tests
    /// consult this gate and each probe posts the SAME key (F19). On a machine
    /// where delivery is slow rather than absent, probe #1 times out and reports
    /// "incapable" -- but its event is still queued, and arrives while probe #2
    /// holds the binding, which then reports "capable" off someone else's
    /// keypress. That is exactly what happened on 2026-07-25: run the suite and
    /// two synthesis tests skipped ("cannot deliver") while the third believed
    /// the gate, ran, and failed; run that third test ALONE and it skipped 3/3.
    /// A red that appears only in a full-suite run and vanishes in isolation is
    /// the most expensive kind, and it was reporting a broken app when the app
    /// was fine. One probe per process cannot disagree with itself.
    private static var synthesisCapable: Bool?

    private func probeSynthesisCapability() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // Drain anything already in flight, so this probe answers about ITSELF
        // and not about an event some earlier test posted.
        pumpAppEvents(0.2)
        var fired = false
        guard let unbind = HotkeyCenter.shared.bind(mods: [], key: "f19", handler: { fired = true })
        else { return false }
        defer { unbind() }
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F19), keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_F19), keyDown: false)?
            .post(tap: .cghidEventTap)
        // Condition wait, not a flat sleep: a capable-but-loaded machine answers
        // in milliseconds and should not pay a fixed cost, while a slow one gets
        // a real ceiling instead of a 0.3s guess that decides capability by luck.
        return waitUntil(2.0) { fired } && fired
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

    // The "safe gate" for native pages: the Swift FeaturePageRegistry.roster and
    // the on-disk feature.json `page` declarations are coupled ONLY by a matching
    // id string, with no compiler check -- a typo or a forgotten half makes the
    // page silently never render. This test is that check, run as part of
    // `swift test` (the pre-package CI gate): roster ids and declared-page ids
    // must be the same set, in BOTH directions, and it names the offender.
    func testFeaturePageRosterMatchesDeclarations() {
        host.store.refresh()
        let declared = Set(host.store.features.filter { $0.page != nil }.map(\.id))
        let registered = FeaturePageRegistry.shared.registeredIds

        let providerWithoutPage = registered.subtracting(declared).sorted()
        XCTAssertEqual(providerWithoutPage, [],
            "FeaturePageRegistry.roster names provider(s) whose feature.json declares no `page`: \(providerWithoutPage)")

        let pageWithoutProvider = declared.subtracting(registered).sorted()
        XCTAssertEqual(pageWithoutProvider, [],
            "feature.json declares a `page` with no provider in FeaturePageRegistry.roster (it will never render): \(pageWithoutProvider)")
    }

    // The Feature Gallery gives every card an animated hover preview via
    // FeatureArchetype.of(feature); an id missing from that switch falls through
    // to `.none` and the card silently ships with just its static icon. NOTHING
    // else couples the growing catalog to that switch, so a newly added feature
    // slips through unnoticed -- exactly how window_grid / window_deck /
    // confirm_shortcut / notify_on_trigger each regressed after landing. This is
    // that check: every non-failed catalog feature (preferences included -- the
    // Gallery shows them too) must map to a real archetype. A feature with
    // genuinely nothing to animate goes in `previewExempt` WITH a reason -- empty
    // today, on purpose.
    func testEveryGalleryFeatureHasAPreview() {
        host.store.refresh()
        // Guard against a vacuous pass: refresh() early-returns WITHOUT clearing
        // `features` on a bridge read failure, so an empty catalog would sail
        // through the filter below. Assert we actually have features to check.
        XCTAssertFalse(host.store.features.isEmpty, "catalog read produced no features")
        let previewExempt: Set<String> = []   // none: every feature earns a preview

        // A DECLARED preview must resolve -- even for an exempt feature. Exemption
        // means "this one needs no preview", not "this one's declaration is
        // unchecked": filtering exempt ids out before the resolution check would
        // let a typo'd archetype/sample sit there permanently unverified, and the
        // exemption would be silently doing double duty as a suppression.
        let brokenDeclaration = host.store.features
            .filter { !$0.failed && $0.previewArchetype != nil }
            .filter { if case .none = FeatureArchetype.of($0) { return true } else { return false } }
            .map(\.id)
            .sorted()
        XCTAssertEqual(brokenDeclaration, [],
            "these features DECLARE a preview that does not resolve -- the archetype or "
            + "sample name is wrong (an unknown name falls back to no preview rather than "
            + "to a wrong one, by design): \(brokenDeclaration)")

        // A sample named for an archetype that takes none is a declaration that
        // lies: it resolves fine and the extra word is silently dropped, so the
        // file claims a payload the Gallery never shows.
        let sampleless: Set<String> = ["windowGrid", "windowDeck", "windowFan", "windowRewind",
                                       "countdownStrip", "pointerPulse", "pointerFollow",
                                       "passwordReveal", "chart", "wallpaperSwap"]
        let straySample = host.store.features
            .filter { !$0.failed && $0.previewSample != nil }
            .filter { sampleless.contains($0.previewArchetype ?? "") }
            .map { "\($0.id) (\($0.previewArchetype ?? "?"))" }
            .sorted()
        XCTAssertEqual(straySample, [],
            "these features name a preview.sample for an archetype that takes none -- "
            + "the value is ignored, so the declaration is misleading: \(straySample)")

        let missing = host.store.features
            .filter { !$0.failed && !previewExempt.contains($0.id) }
            .filter { if case .none = FeatureArchetype.of($0) { return true } else { return false } }
            .map(\.id)
            .sorted()
        XCTAssertEqual(missing, [],
            "these Gallery features have no archetype preview -- give each a "
            + "\"preview\": { \"archetype\": ..., \"sample\": ... } in its feature.json "
            + "(this is ALSO what a typo'd archetype or sample name looks like, since "
            + "an unresolved name deliberately falls back to no preview rather than to "
            + "a wrong one -- check the names against FeatureArchetype.of and the "
            + "sample type's `named(_:)`). If there is truly nothing to show, add the "
            + "id to previewExempt with a reason: \(missing)")
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

    // The Keychain seam round-trips through the real Lua adapter: set, read
    // back, delete, read nil. Uses a throwaway account and cleans up after.
    func testKeychainSeamRoundTrip() throws {
        try requireUITests()   // login-Keychain access can prompt; opt-in only
        let acct = "hammerdeck.it.secret.\(ProcessInfo.processInfo.globallyUniqueString)"
        defer { eval("require('platform.adapter').secretDelete('\(acct)'); return true") }

        eval("require('platform.adapter').secretSet('\(acct)', 'sk-abc'); return true")
        XCTAssertEqual(eval("return require('platform.adapter').secretGet('\(acct)')") as? String,
                       "sk-abc", "secret reads back from the Keychain")
        // It must NOT be in UserDefaults.
        XCTAssertNil(UserDefaults.standard.object(forKey: acct),
                     "a secret never lands in UserDefaults")

        eval("require('platform.adapter').secretDelete('\(acct)'); return true")
        XCTAssertNil(eval("return require('platform.adapter').secretGet('\(acct)')"),
                     "deleted secret reads nil")
    }

    // A `secret`-typed option routes through the Keychain (not UserDefaults) on
    // both the write side (SettingsStore) and the read side (ctx.secret), under
    // the same hammerdeck.opt.<id>.<key> account namespace.
    func testSecretOptionRoutesToKeychainNotDefaults() throws {
        try requireUITests()   // login-Keychain access can prompt; opt-in only
        guard let opt = OptionInfo(["key": "openaiKey", "type": "secret", "label": "k"]) else {
            return XCTFail("could not build a secret OptionInfo")
        }
        // A THROWAWAY feature id (not a real feature's), so the test owns a fresh
        // Keychain item and never collides with -- nor prompts for access to, nor
        // deletes -- a real feature's stored secret (e.g. a user's actual
        // text_actions OpenAI key) in the login Keychain. The namespace pattern
        // (hammerdeck.opt.<id>.<key>) is what's under test, not the literal id.
        let fid = "ittest.\(ProcessInfo.processInfo.globallyUniqueString)"
        let acct = "hammerdeck.opt.\(fid).openaiKey"
        defer { host.store.resetOption(fid, opt) }

        host.store.setOptionValue(fid, opt, "sk-xyz")
        XCTAssertNil(UserDefaults.standard.object(forKey: acct),
                     "secret option must not write UserDefaults")
        XCTAssertEqual(host.store.optionValue(fid, opt) as? String, "sk-xyz",
                       "store reads the secret back from the Keychain")
        XCTAssertTrue(host.store.isOptionOverridden(fid, opt),
                      "a stored secret counts as overridden")
        // A feature reads it via ctx.secret (same account namespace).
        XCTAssertEqual(
            eval("return require('platform.adapter').secretGet('\(acct)')") as? String, "sk-xyz",
            "ctx.secret/adapter reads what the Settings store wrote")

        host.store.resetOption(fid, opt)
        XCTAssertFalse(host.store.isOptionOverridden(fid, opt),
                       "reset clears the secret")
    }

    // The validate-gating mechanics (the network call itself is host-only and not
    // unit-tested): the durable validated flag lives in feature STATE, the feature
    // reads it via ctx.getState, fetched choices parse from state, and editing the
    // credential re-locks (clears the flag).
    func testValidationGatingStateRoundTrip() {
        let validatedKey = "hammerdeck.state.text_actions.openaiKey__validated"
        let modelsKey = "hammerdeck.state.text_actions.openaiKey__models"
        guard let secret = OptionInfo(
            ["key": "openaiKey", "type": "secret", "label": "k", "validate": "openai"]) else {
            return XCTFail("could not build a validatable secret OptionInfo")
        }
        defer {
            UserDefaults.standard.removeObject(forKey: validatedKey)
            UserDefaults.standard.removeObject(forKey: modelsKey)
            host.store.resetOption("text_actions", secret)
        }

        XCTAssertFalse(host.store.isValidated("text_actions", "openaiKey"),
                       "unset -> not validated")

        // The durable flag the host writes on success; the feature reads the SAME
        // key via ctx.getState (adapter.getSetting proves the round-trip).
        UserDefaults.standard.set(true, forKey: validatedKey)
        XCTAssertTrue(host.store.isValidated("text_actions", "openaiKey"))
        XCTAssertEqual(
            eval("return require('platform.adapter').getSetting('\(validatedKey)', false)") as? Bool,
            true, "the feature reads the validated flag through the seam")

        // Fetched choices parse from the JSON the host stores.
        UserDefaults.standard.set("[\"gpt-4o\",\"gpt-4o-mini\"]", forKey: modelsKey)
        XCTAssertEqual(host.store.fetchedChoices("text_actions", "openaiKey"),
                       ["gpt-4o", "gpt-4o-mini"], "fetched model list parses from state")

        // Editing the credential re-locks the gate.
        host.store.setOptionValue("text_actions", secret, "sk-new")
        XCTAssertFalse(host.store.isValidated("text_actions", "openaiKey"),
                       "editing the key clears the validated flag")
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

    // THE CATEGORY VOCABULARY GATE.
    //
    // `category` is declared in feature.json, ENFORCED in Lua, and rendered by
    // three consumers that cannot import each other: Swift owns the label, tint,
    // glyph and section order; a standalone Python script groups the README by it
    // WITHOUT booting Lua (deliberately -- see its header); the zh-Hans catalog
    // translates it. Four runtimes, one vocabulary, and until this test the only
    // thing holding them together was a comment saying "keep these in step".
    //
    // That convention demonstrably does not hold. The re-cut of 2026-07-28 updated
    // three copies and missed a FOURTH -- a hardcoded category list in the
    // Automation Timeline's legend -- which went on advertising two retired names
    // as gray dots. Nothing failed: the build was clean, every test green, and
    // `gen-readme-features.py --check` in sync, because a stale category name is
    // not a type error anywhere. It is only wrong pixels. (That copy is now
    // derived rather than listed, so it cannot drift again; this gate covers the
    // three that must stay hand-written.)
    func testCategoryVocabularyIsConsistent() throws {
        // 1. The enforcement set, read off the Lua module rather than re-listed
        //    here -- a test that hardcodes the vocabulary is just a fifth copy.
        guard let joined = eval("""
            local m = require('platform.manifest')
            local out = {}
            for c in pairs(m.KNOWN_CATEGORIES) do out[#out + 1] = c end
            table.sort(out)
            return table.concat(out, ',')
            """) as? String, !joined.isEmpty else {
            return XCTFail("manifest.KNOWN_CATEGORIES is not exported -- the gate has nothing to compare against")
        }
        let vocabulary = Set(joined.split(separator: ",").map(String.init))

        // 2. Swift: CATEGORY_ORDER must be the same SET (so a new category gets a
        //    deterministic slot instead of silently sorting last) and carry no
        //    duplicate, which would render one section twice.
        XCTAssertEqual(Set(CATEGORY_ORDER), vocabulary,
                       "CATEGORY_ORDER (FeatureChrome.swift) and KNOWN_CATEGORIES (manifest.lua) disagree")
        XCTAssertEqual(CATEGORY_ORDER.count, Set(CATEGORY_ORDER).count,
                       "CATEGORY_ORDER lists a category twice")

        // 3. Swift presentation. Assert against the documented FALLBACKS -- gray and
        //    puzzlepiece are what an unknown category gets -- rather than sniffing
        //    whether a label "looks" localized: `categoryLabel("text")` legitimately
        //    returns "Text", which is exactly what the raw-value fallback would also
        //    produce, so a sniffing check would fail on a correctly-presented value.
        //    `general` IS the unknown-ish default and opts out of both.
        for c in vocabulary where c != "general" {
            XCTAssertNotEqual(categoryColor(c), .gray,
                              "category '\(c)' has no categoryColor case -- it renders in the fallback gray")
            XCTAssertNotEqual(categoryIcon(c), "puzzlepiece.fill",
                              "category '\(c)' has no categoryIcon case -- it renders the fallback glyph")
        }

        // 4. The README generator's grouping. Parsed from source because the script
        //    is intentionally standalone; a category missing here still renders, but
        //    under its raw id as a heading in the PUBLIC README.
        let genPath = TestHost.repoRoot + "/scripts/gen-readme-features.py"
        let gen = try String(contentsOfFile: genPath, encoding: .utf8)
        guard let block = gen.range(of: "GROUPS = ["),
              let end = gen.range(of: "]", range: block.upperBound..<gen.endIndex) else {
            return XCTFail("could not find the GROUPS list in \(genPath)")
        }
        let groups = gen[block.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let l = line.range(of: "(\""), let r = line.range(of: "\",", range: l.upperBound..<line.endIndex)
                else { return nil }
                return String(line[l.upperBound..<r.lowerBound])
            }
        XCTAssertEqual(Set(groups), vocabulary,
                       "GROUPS (gen-readme-features.py) and KNOWN_CATEGORIES (manifest.lua) disagree")

        // The two lists must agree on the SEQUENCE, not merely the membership.
        // Comparing sets is what the first cut of this gate did, and it left the
        // hole the gate was written to close: CATEGORY_ORDER exists precisely so
        // section order stops being an accident, but with a set comparison the
        // README could print Health before Windows while Settings printed the
        // reverse, and nothing would fail. Same eight names, two different
        // products.
        XCTAssertEqual(groups, CATEGORY_ORDER,
                       "GROUPS (gen-readme-features.py) and CATEGORY_ORDER (FeatureChrome.swift) "
                       + "hold the same categories in a DIFFERENT order -- the README and the "
                       + "Settings sidebar would show their sections in different orders")

        // 5. Translation. Every category needs a `category.<id>` key -- and because
        //    the only thing that MINTS such a key is a Strings.t call in
        //    categoryLabel (testEveryChromeStringIsTranslated forces the catalog to
        //    carry every key, testCatalogHasNoOrphanedKeys forbids the reverse), a
        //    present key transitively proves the label case exists.
        let catalog = TestHost.repoRoot + "/app/i18n/zh-Hans.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: catalog))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for c in vocabulary {
            XCTAssertNotNil(keys["category.\(c)"],
                            "category '\(c)' has no 'category.\(c)' key in zh-Hans.json -- so it has no "
                            + "categoryLabel case either, and its section header renders untranslated")
        }
    }

    // The card data the Gallery renders, end to end through the real bridge:
    // category + one-line description, the service/action distinction (a pure
    // service has no actions, so its card shows "always on"), and the
    // store-level selection the card click deep-links into the Settings detail.
    func testGalleryCardDataAndDeepLink() {
        host.store.refresh()

        let palette = host.store.features.first { $0.id == "command_palette" }
        XCTAssertEqual(palette?.category, "switching")
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
        waitUntil(5.0) { eval("return _G.itTimerFired") as? Bool == true }
        XCTAssertEqual(eval("return _G.itTimerFired") as? Bool, true)
    }

    func testDiscoveryScansTheRealFilesystem() throws {
        let tmp = NSTemporaryDirectory() + "hammerdeck-it-\(getpid())"
        let fm = FileManager.default
        // Co-located layout: a feature is a folder whose Lua entry point is at
        // <id>/lua/init.lua. A bare init.lua at the folder root (old layout), a
        // flat <name>.lua, and junk all fail to count.
        try fm.createDirectory(atPath: tmp + "/foo/lua", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmp + "/old_layout", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmp + "/not_a_feature", withIntermediateDirectories: true)
        try "return {}".write(toFile: tmp + "/foo/lua/init.lua", atomically: true, encoding: .utf8)
        try "return {}".write(toFile: tmp + "/old_layout/init.lua", atomically: true, encoding: .utf8)
        try "return {}".write(toFile: tmp + "/bar.lua", atomically: true, encoding: .utf8)
        try "junk".write(toFile: tmp + "/junk.txt", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: tmp) }

        let raw = eval("return require('platform.adapter').discoverFeatures('\(tmp)')") as? [Any]
        let names = raw?.compactMap { $0 as? String }.sorted()
        XCTAssertEqual(names, ["foo"],
                       "only a folder with lua/init.lua counts; bare init.lua, flat .lua, and junk don't")
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

    #if DEBUG
    // Regression for two leaks the reviewer caught: freeResource forgot to clear
    // the scrims/deckWidgets dicts (stranded an NSPanel per deck cycle) and the
    // deck-widget canceller never released its 5 pinned Lua callback refs. Both
    // are invisible to the fake-adapter suite -- only the REAL bridge dicts +
    // pinnedRefCount catch them. Create + stop repeatedly: the pinned-ref count
    // and both panel dicts must return exactly to baseline every cycle.
    func testDeckChromeReleasesRefsAndPanels() throws {
        try requireUITests()   // both create real always-front NSPanels
        let lua = host.lua
        let baseRefs = lua.pinnedRefCount
        let baseWidgets = Native.shared.deckWidgets.count
        let baseScrims = Native.shared.scrims.count
        for _ in 0..<3 {
            eval("""
            _G.itW = require('platform.adapter').deckWidget({
                title='T', name='n', switchHint='s',
                pos={x=100,y=100}, screen={x=0,y=0,w=1440,h=900},
                switcher={cols=2, colors={'#ff0000','#00ff00'},
                          onSwitch=function() end, onReorder=function() end},
                onMove=function() end, onExit=function() end,
                onToggleHero=function() end, onRearrange=function() end,
            }); return true
            """)
            XCTAssertEqual(lua.pinnedRefCount, baseRefs + 6, "the deck widget pins its 6 callbacks")
            XCTAssertEqual(Native.shared.deckWidgets.count, baseWidgets + 1, "and registers one panel")
            eval("_G.itW.stop(); _G.itW = nil; return true")
            XCTAssertEqual(lua.pinnedRefCount, baseRefs, "stopping the widget releases all 6 refs")
            XCTAssertEqual(Native.shared.deckWidgets.count, baseWidgets, "and clears its dict entry")

            // The scrim pins no refs but its dict entry must still be freed.
            eval("_G.itS = require('platform.adapter').scrim({x=0,y=0,w=1440,h=900}, 0.5); return true")
            XCTAssertEqual(Native.shared.scrims.count, baseScrims + 1, "the scrim registers a panel")
            eval("_G.itS.stop(); _G.itS = nil; return true")
            XCTAssertEqual(Native.shared.scrims.count, baseScrims, "the scrim dict entry is freed on stop")
        }
        XCTAssertEqual(lua.pinnedRefCount, baseRefs, "no pinned ref leaks across deck-chrome cycles")
    }
    #endif

    #if DEBUG
    // The spatial display picker (DisplayPickerPanel) drives a real NSPanel, but
    // its seam wiring -- pin the onPick ref, register the panel, then release BOTH
    // when the one-shot completes -- is only observable on the REAL bridge (the
    // same leak class the deck-chrome test guards). Also drives the panel's
    // selection + confirm and asserts the pick flows back through the seam to Lua.
    func testDisplayPickerRegistersDrivesAndReleases() throws {
        try requireUITests()   // creates a real always-front NSPanel
        let lua = host.lua
        let baseRefs = lua.pinnedRefCount
        let basePickers = Native.shared.displayPickers.count
        eval("""
        _G.itDPpick = nil
        _G.itDP = require('platform.adapter').pickDisplays({
            displays = {
                {x=0,    y=0, w=1440, h=900,  name='Built-in', windows=2},
                {x=1440, y=0, w=2560, h=1440, name='DELL',     windows=1},
                {x=4000, y=0, w=2560, h=1440, name='LG',       windows=0},
            },
            preselect = {1, 2}, selectCount = 2, title='Swap', prompt='p', confirmVerb='Swap',
            onPick = function(sel) _G.itDPpick = sel end,
        }); return true
        """)
        XCTAssertEqual(lua.pinnedRefCount, baseRefs + 1, "the picker pins its onPick callback")
        XCTAssertEqual(Native.shared.displayPickers.count, basePickers + 1, "and registers one panel")

        let panel = Native.shared.displayPickers.values.first
        XCTAssertEqual(panel?.selectedOneBased, [1, 2], "preselect seeds the two selected displays")
        XCTAssertEqual(panel?.displayCount, 3, "all displays are handed to the map")
        // Change the pair off the map: deselect Built-in, select LG -> {2, 3}.
        panel?.debugToggle(1)
        panel?.debugToggle(3)
        panel?.debugConfirm()
        XCTAssertEqual(
            eval("return _G.itDPpick and #_G.itDPpick == 2 and _G.itDPpick[1] == 2 and _G.itDPpick[2] == 3")
                as? Bool, true,
            "confirming returns the chosen pair {2,3} to the Lua onPick")
        XCTAssertEqual(Native.shared.displayPickers.count, basePickers,
                       "the one-shot frees its panel dict entry on confirm")
        XCTAssertEqual(lua.pinnedRefCount, baseRefs, "and releases the pinned callback ref")
        eval("_G.itDP = nil; _G.itDPpick = nil; return true")
    }
    #endif

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

    /// CLICKING an amber (chord-prefix) cap on the Hyper board must ARM the
    /// chord, never fire one -- the board shows only ONE of the several actions
    /// that can share a prefix, so firing would pick arbitrarily.
    ///
    /// The trap this pins is the self-referential chord, whose follow key IS its
    /// prefix key (locate_pointer ships exactly that: Hyper+M then M). Routing
    /// the click through `prefixPressed` would hit its "already armed -> treat
    /// this as the follow key" fast path, whose entire justification is that the
    /// keyboard leader is HELD -- which a click never is. A user who clicks the
    /// cap, re-opens the board and clicks again (the natural "did that work?"
    /// reaction, well inside the 2.1s window) would then RUN the action.
    ///
    /// Bound directly on ChordCenter rather than through a feature, so a
    /// regression asserts on a counter instead of firing a real action into
    /// whatever the developer has focused.
    func testClickingAChordPrefixArmsAndNeverFires() {
        let chord = ChordCenter.shared
        var fired = 0
        guard let id = chord.bind(mods: ["cmd", "alt", "ctrl"], key: "m", follows: ["m"],
                                  label: "click probe", handler: { fired += 1 }) else {
            return XCTFail("could not register the probe chord")
        }
        defer { chord.unbind(id) }   // unbind disarms if this prefix is still armed

        XCTAssertTrue(chord.pressPrefix(mods: ["cmd", "alt", "ctrl"], key: "m"),
                      "clicking a bound chord cap arms it")
        XCTAssertTrue(chord.isArmed, "the chord is armed after the click")
        XCTAssertTrue(chord.pressPrefix(mods: ["cmd", "alt", "ctrl"], key: "m"),
                      "a second click re-arms")
        XCTAssertTrue(chord.isArmed, "still armed after the second click")
        XCTAssertEqual(fired, 0, "a click must never complete the chord, however many times")

        // Modifier ORDER/alias must not matter -- the prefix is canonicalized.
        XCTAssertTrue(chord.pressPrefix(mods: ["control", "command", "option"], key: "M"),
                      "the clicked prefix is canonicalized before lookup")

        // An unbound prefix is a no-op: arming it would grab Escape system-wide
        // for the timeout window and show a hint with no rows.
        chord.unbind(id)
        XCTAssertFalse(chord.isArmed, "unbinding the last chord disarms its prefix")
        XCTAssertFalse(chord.pressPrefix(mods: ["cmd", "alt", "ctrl"], key: "m"),
                       "clicking a prefix nobody has bound arms nothing")
        XCTAssertFalse(chord.isArmed, "and leaves nothing armed")
    }

    /// The RESPONDER-CHAIN half of the background-click dismissal: a click no
    /// view claims has to walk all the way to the WINDOW -- the only place to
    /// catch "clicked the chrome" without blanketing the card in a swallowing
    /// overlay that would shadow its real controls.
    ///
    /// SCOPE, deliberately stated: `sendEvent` enters below the layer where
    /// AppKit decides first-mouse delivery, so this cannot tell you whether a
    /// REAL click reaches the panel at all -- it would pass either way. That
    /// half was settled separately, on-device, with a posted CGEvent (see
    /// HyperKeyView.acceptsFirstMouse). Do not let this test's green stand in
    /// for that question.
    func testUnclaimedClickReachesThePanelBackground() {
        // Parked far off every display: AppKit only hit-tests an ON-SCREEN
        // window, so the panel has to be ordered in -- but nothing should flash.
        let panel = FloatingPanel(contentRect: NSRect(x: -9000, y: -9000, width: 200, height: 100),
                                  mouseTransparent: false)
        // A plain NSView does not implement mouseDown, so it passes the event on.
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var clicks = 0
        panel.onBackgroundClick = { clicks += 1 }
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else {
            return XCTFail("could not synthesize the click")
        }
        panel.sendEvent(click)
        XCTAssertEqual(clicks, 1, "an unclaimed click reaches the window's background handler")

        // Default (nil) must stay inert -- the informational HUDs share this base.
        panel.onBackgroundClick = nil
        panel.sendEvent(click)
        XCTAssertEqual(clicks, 1, "a panel that declares no handler is unaffected")
    }

    /// The other half of the mouse path: after a click ARMS a chord, clicking a
    /// row on the follow-key card must pick that key. chooseFollow defers a
    /// main-loop pass (the click is still unwinding and advance() can run the
    /// action), so the assertions wait on the run loop rather than the return.
    func testClickingAFollowKeyCompletesTheChord() {
        let chord = ChordCenter.shared
        var fired = 0
        guard let id = chord.bind(mods: ["cmd", "alt", "ctrl"], key: "y", follows: ["b"],
                                  label: "follow probe", handler: { fired += 1 }) else {
            return XCTFail("could not register the probe chord")
        }
        defer { chord.unbind(id) }

        XCTAssertTrue(chord.pressPrefix(mods: ["cmd", "alt", "ctrl"], key: "y"))

        // A key that is NOT live at this level must be ignored, not disarm.
        chord.chooseFollow("q")
        pumpRunLoop()
        XCTAssertTrue(chord.isArmed, "a follow key that isn't live leaves the chord armed")
        XCTAssertEqual(fired, 0, "and fires nothing")

        chord.chooseFollow("b")
        pumpRunLoop()
        XCTAssertEqual(fired, 1, "clicking the live follow key completes the chord")
        XCTAssertFalse(chord.isArmed, "and disarms it")

        // With nothing armed, a stray click (a card racing its own teardown)
        // must be inert rather than reviving the chord.
        chord.chooseFollow("b")
        pumpRunLoop()
        XCTAssertEqual(fired, 1, "a click with nothing armed fires nothing")
    }

    /// Let queued main-queue work (chooseFollow's deferral) run.
    private func pumpRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
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

    /// AX COLD-START WARM-UP plumbing. An app whose accessibility tree is cold
    /// needs far longer than the 0.3s steady-state ceiling for its FIRST kAXWindows
    /// read (measured: 0.527s cold, ~0.010s warm), so a fixed ceiling can never pay
    /// the handshake -- the app fails, stays cold, and its windows are missing from
    /// EVERY listing. warmAXConnection pays it once on a background queue.
    ///
    /// Tested against a pid that cannot answer, because the failure mode that would
    /// silently DISABLE the fix is bookkeeping, not AX: if the rate limit is not
    /// applied, every listing re-probes a wedged app and the warm-ups become the
    /// storm they exist to prevent (window_fan lists several times per focus event).
    /// That shows up as neither a crash nor a log line, so nothing else catches it.
    func testAXWarmUpRateLimitsARepeatedProbe() {
        let native = Native.shared
        // A pid that owns no process (pid 0 is the kernel; AX cannot answer for it).
        let deadPid: pid_t = 0
        native.axWarmAttemptedAt.removeValue(forKey: deadPid)

        native.warmAXConnection(pid: deadPid, appName: "WarmUpProbe", ceiling: 0.2)
        let firstAttempt = native.axWarmAttemptedAt[deadPid]
        XCTAssertNotNil(firstAttempt, "an accepted warm-up records its attempt time")

        // Every subsequent call inside the window must be a no-op -- not more AX
        // traffic to an app that just failed to answer.
        for _ in 0..<5 {
            native.warmAXConnection(pid: deadPid, appName: "WarmUpProbe", ceiling: 0.2)
        }
        XCTAssertEqual(native.axWarmAttemptedAt[deadPid], firstAttempt,
                       "repeat probes inside the rate-limit window are suppressed")

        // Once the window has passed, the app becomes eligible again -- a wedged app
        // that later recovers must not be locked out forever. Compare against the
        // value actually WRITTEN, not a recomputed one: `Date()` moves between the
        // two calls, so a recomputed expectation makes the assertion pass sometimes
        // even when the warm-up was wrongly refused.
        let stale = Date().addingTimeInterval(-31)
        native.axWarmAttemptedAt[deadPid] = stale
        native.warmAXConnection(pid: deadPid, appName: "WarmUpProbe", ceiling: 0.2)
        XCTAssertNotEqual(native.axWarmAttemptedAt[deadPid], stale,
                          "after the rate-limit window a fresh warm-up is accepted")

        native.axWarmAttemptedAt.removeValue(forKey: deadPid)
    }

    /// The seam must report which apps it FAILED to read, because absence from a
    /// window listing is otherwise ambiguous -- a closed window and a window whose
    /// app went quiet look identical, and window_fan destroyed captured window
    /// geometry by guessing (2026-07-25). A clean listing reports nothing.
    /// Deliberately does NOT list first (a real AX enumeration costs seconds when
    /// the test process is cold, and the post-listing shape is asserted inside
    /// testRealWindowListingViaAX, which already pays for one): the contract checked
    /// here is that the reader always answers a table, including before any listing.
    /// The fan widget's row list must never make the card taller than the screen.
    /// When it did, `clamped()` pinned the card's origin to the screen bottom so it
    /// grew UPWARD, carrying the header -- and the Exit button -- off the top edge:
    /// Exit became unreachable exactly when the list was longest. The fan's capacity
    /// gate hid this by keeping row counts in single digits; LABEL MODE has no window
    /// limit by design, so the bound has to hold on its own.
    ///
    /// Asserted on the pure clamp rather than through pixels: a screenshot check needs
    /// an unlocked screen and Screen Recording, and a locked display returns an
    /// all-black frame that passes every "X is not off-screen" assertion silently
    /// (that happened while this was being written).
    ///
    /// `chrome` is an INPUT here, not a constant this re-derives -- an earlier version
    /// asserted `listHeight(...) + chromeHeight < screenHeight` against a hardcoded
    /// chrome, which is algebraically true for ANY value of it and so could never catch
    /// the drift its own comment claimed to guard. The real defence is that the panel
    /// now MEASURES chrome from the live view tree, so there is no constant left to
    /// drift; what remains testable, and tested here, is the clamping itself.
    func testFanWidgetListNeverOutgrowsTheScreen() {
        let screenH: CGFloat = 938          // the author's built-in display
        let chrome: CGFloat = 49            // measured from the real tree: 898pt card

        // 30 rows (row 28pt + 3pt spacing) is ~927pt of content -- taller than the
        // screen once chrome is added. It must be capped, not passed through.
        let tall = FanWidgetPanel.listHeight(content: 927, screenHeight: screenH, chrome: chrome)
        XCTAssertLessThan(tall, 927, "the over-long content was actually capped")
        XCTAssertLessThanOrEqual(tall + chrome, screenH,
                                 "a 30-row list leaves the card no taller than the screen")

        // A short list is untouched, so the common case looks exactly as before.
        XCTAssertEqual(FanWidgetPanel.listHeight(content: 160, screenHeight: screenH, chrome: chrome),
                       160, "content that already fits is passed through unchanged")

        // The cap is a function of the SCREEN, so a bigger chrome must yield a smaller
        // list -- this is the part a self-referential assertion could not see.
        XCTAssertLessThan(FanWidgetPanel.listHeight(content: 5_000, screenHeight: screenH, chrome: 200),
                          FanWidgetPanel.listHeight(content: 5_000, screenHeight: screenH, chrome: 49),
                          "more chrome must leave less room for rows")

        for content in [0, 500, 2_000, 100_000] as [CGFloat] {
            XCTAssertLessThanOrEqual(
                FanWidgetPanel.listHeight(content: content, screenHeight: screenH, chrome: chrome) + chrome,
                screenH, "bounded at content=\(content)")
        }

        // The floor is deliberate and DOCUMENTED as breaking the bound: a list too
        // short to show a row is useless, so on a tiny display the floor wins. Asserted
        // so the behaviour and the docstring cannot drift apart.
        // (The floor only wins below ~169pt with this chrome: 200 - 49 - 40 = 111 still
        // clears 80, so a 200pt screen is bounded normally.)
        XCTAssertLessThanOrEqual(
            FanWidgetPanel.listHeight(content: 900, screenHeight: 200, chrome: chrome) + chrome,
            200, "a 200pt screen is still bounded -- the floor has not kicked in yet")
        let tiny = FanWidgetPanel.listHeight(content: 900, screenHeight: 120, chrome: chrome)
        XCTAssertEqual(tiny, 80, "a very short screen falls back to the minimum row area")
        XCTAssertGreaterThan(tiny + chrome, 120, "and that floor knowingly exceeds such a screen")
    }

    func testDroppedAppsAlwaysAnswersATable() {
        let dropped = eval("return require('platform.adapter').windowsDroppedApps()") as? [Any]
        XCTAssertNotNil(dropped, "windowsDroppedApps always answers a table, never nil")
        // Deliberately NOT asserting emptiness: whether a listing has run by now
        // depends on global test order and on whether this machine has a slow app,
        // neither of which is a property of the code under test.
    }

    func testRealWindowListingViaAX() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
            "needs Accessibility (grant it to the terminal running `swift test`)")
        try XCTSkipUnless(!sessionLocked(),
            "screen is locked; AX lists no windows behind the lock")
        // A CI runner can report AX-trusted yet have a windowless virtual desktop
        // (no apps on it), so the "at least one window" assertion below would fail
        // for an environment reason, not a regression. This test needs a real
        // interactive session; skip it on CI.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
            "CI session has no real desktop windows to list")

        XCTAssertEqual(eval("return require('platform.adapter').axTrusted()") as? Bool, true)

        let raw = eval("return require('platform.adapter').listWindows()") as? [Any]
        let rows = raw?.compactMap { $0 as? [String: Any] } ?? []
        XCTAssertFalse(rows.isEmpty, "a real desktop session has at least one window")

        // Riding this listing (rather than paying for another): whatever the seam
        // reports as DROPPED must be usable as the bundle-id key window_fan matches
        // on -- an empty id there would silently classify a live app as absent.
        for entry in eval("return require('platform.adapter').windowsDroppedApps()") as? [Any] ?? [] {
            let id = entry as? String
            XCTAssertNotNil(id, "dropped entries are bundle id strings")
            XCTAssertFalse((id ?? "").isEmpty, "a dropped entry is never the empty id")
        }
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

    /// Regression (2026-07-18): a window keeps the SAME handle id across
    /// successive list_windows() calls -- keyed by its stable CGWindowID -- so a
    /// feature that LISTS, shows a chooser, then focuses on the user's pick still
    /// resolves that pick even though ANOTHER feature (Window Fan) re-lists
    /// windows in between. The old cache wiped itself and reassigned ids on every
    /// listing, so the held id silently no-oped focus_window -- the "window
    /// switcher can't switch (esp. same-app) windows" bug. Asserts the invariant
    /// the fix restores (stable, wid-keyed ids), not an implementation detail.
    func testWindowIdStableAcrossListings() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
            "needs Accessibility (grant it to the terminal running `swift test`)")
        try XCTSkipUnless(!sessionLocked(),
            "screen is locked; AX lists no windows behind the lock")
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
            "CI session has no real desktop windows to list")

        func listRows() -> [[String: Any]] {
            let raw = eval("return require('platform.adapter').listWindows()") as? [Any]
            return raw?.compactMap { $0 as? [String: Any] } ?? []
        }

        // Listing #1 == the switcher's "open" pass. Hold a handle to the FRONTMOST
        // window (row 1): it must have a resolved wid (the fix keys stability on
        // it), and re-focusing the front window at the end is a visual no-op.
        let rows1 = listRows()
        guard let target = rows1.first,
              (target["wid"] as? Double ?? 0) != 0,
              let targetId = (target["id"] as? Double).map(Int.init),
              let targetWid = (target["wid"] as? Double).map(Int.init) else {
            throw XCTSkip("frontmost window has no resolved CGWindowID to key identity on")
        }

        // Another feature (Window Fan) re-lists windows while the chooser is open.
        let rows2 = listRows()

        // The SAME window (matched by its stable wid) must keep the SAME id...
        let same = rows2.first { ($0["wid"] as? Double).map(Int.init) == targetWid }
        XCTAssertNotNil(same, "the window is still present in the second listing")
        XCTAssertEqual((same?["id"] as? Double).map(Int.init), targetId,
            "a window keeps its handle id across listings (stable, wid-keyed)")

        // ...and the handle held from listing #1 still resolves: focus succeeds
        // instead of no-oping (pre-fix this returned false against a wiped cache).
        XCTAssertEqual(eval("return require('platform.adapter').focusWindow(\(targetId))") as? Bool,
                       true, "a handle held across another feature's re-list still focuses")
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
        guard NSRunningApplication.current.isActive, NSApp.keyWindow is FloatingPanel else {
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

    /// Closed-loop chooser navigation: tab / shift+tab / option+arrows step the
    /// selection via the panel's local key monitor -- the mid-cycle turn-around
    /// path. These MUST be monitor-handled (not field-editor selectors): with a
    /// switcher's cycle modifier held, option+arrows arrive as paragraph-
    /// movement selectors (never moveUp:/moveDown:), and releasing the modifier
    /// to recover would commit the pick. Same closed loop as
    /// testTypeTextSynthesisIntoOwnPanel: our own panel is key, so the
    /// synthesized keys land on it.
    func testChooserTabSteppingSynthesis() throws {
        try requireUITests()
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized events")

        eval("""
        _G.itNav = require('platform.adapter').chooser { onSelect = function() end }
        _G.itNav.setPlaceholder('IT Nav Probe')
        _G.itNav.setChoices({ { text = 'one' }, { text = 'two' }, { text = 'three' } })
        _G.itNav.show()
        return true
        """)
        NSApp.activate(ignoringOtherApps: true)
        pumpAppEvents(0.4)   // let the panel become key

        // Same SAFETY GATE as testTypeTextSynthesisIntoOwnPanel: synthesize only
        // when the system agrees OUR panel holds keyboard focus.
        guard NSRunningApplication.current.isActive, NSApp.keyWindow is FloatingPanel else {
            eval("_G.itNav.stop(); _G.itNav = nil; return true")
            throw XCTSkip("test runner cannot take system keyboard focus here; "
                + "refusing to type into another app (covered by "
                + "testGlobalHotkeySynthesis's shared posting path)")
        }

        func row() -> Int {
            (eval("return _G.itNav.getSelectedRow()") as? NSNumber)?.intValue ?? -1
        }
        func stroke(_ mods: String, _ key: String) {
            eval("require('platform.adapter').keyStroke({\(mods)}, '\(key)'); return true")
            pumpAppEvents(0.25)
        }

        XCTAssertEqual(row(), 1, "show() preselects the first valid row")
        stroke("", "tab")
        XCTAssertEqual(row(), 2, "tab steps the selection down")
        stroke("'shift'", "tab")
        XCTAssertEqual(row(), 1, "shift+tab steps back up")
        stroke("'shift'", "tab")
        XCTAssertEqual(row(), 3, "shift+tab wraps from the top row to the bottom")
        stroke("'alt'", "down")
        XCTAssertEqual(row(), 1, "option+down steps (and wraps) while option is held")
        stroke("'alt'", "up")
        XCTAssertEqual(row(), 3, "option+up steps back while option is held")

        // chooser_step over a FILTERED list -- the seam the switchers' hotkey
        // cycle rides. Regression: a Lua-side wrap against the full choice
        // count jammed at row 1 here (setSelectedRow rejects rows beyond the
        // filtered list, including the wrap target).
        func step(_ d: Int) { eval("_G.itNav.step(\(d)); return true") }
        eval("_G.itNav.setQuery('t'); return true")   // matches "two", "three"
        XCTAssertEqual(row(), 1, "applyFilter reselects the first visible row")
        step(-1)
        XCTAssertEqual(row(), 2, "step(-1) wraps within the FILTERED rows")
        step(1)
        XCTAssertEqual(row(), 1, "step(+1) wraps forward within the filtered rows")

        eval("_G.itNav.stop(); _G.itNav = nil; return true")
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
        // Every screen carries a `builtin` flag (CGDisplayIsBuiltin) -- capture
        // uses it to keep only external displays.
        XCTAssertNotNil(s0["builtin"] as? Bool, "screen rows expose a `builtin` flag")

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
            "return pcall(function() require('platform.adapter').browserFocusTab('Evil App', 0, 1, 'https://x/', 0, function() end) end)")
        XCTAssertEqual(r2 as? Bool, false)
        // browserActiveURL is async now (out-of-process), so it refuses the same
        // way its siblings do -- a raise at the bridge, never a script run.
        let r3 = try? host.lua.eval(
            "return pcall(function() require('platform.adapter').browserActiveURL('Evil App', function() end) end)")
        XCTAssertEqual(r3 as? Bool, false,
                       "active-url for a non-whitelisted app must raise, not reach a script")

        XCTAssertEqual(eval("return require('platform.adapter').isAppRunning('NoSuchApp-77')") as? Bool,
                       false)

        // file: icon tokens resolve from disk; a missing path is nil, not a crash.
        XCTAssertNil(ChooserPanel.icon(for: "file:/nonexistent/icon.png"))
    }

    /// LIVENESS GATE -- the 2026-07-23 freeze. A synchronous AppleScript to an app
    /// that is not running does NOT fail fast: `tell` LAUNCHES the app and blocks
    /// the main thread until it is scriptable, and if it never becomes scriptable
    /// the app plays dead. usage_stats polls browserActiveURL on a timer keyed on
    /// the last ACTIVATED app, so once Chrome quit it kept addressing a departed
    /// app every tick -- 25+ unresponsive seconds at ~0% CPU (a hang report, not a
    /// crash).
    ///
    /// Probes the chokepoint directly with a name that can NEVER be running, so
    /// this is deterministic on every machine -- gating on whichever real browser
    /// happens to be closed would skip exactly where it matters. ELAPSED TIME is
    /// the real assertion: returning nil is not enough, it has to return nil
    /// without going near an Apple Event.
    func testAppleScriptChokepointRefusesAbsentTargetInstantly() {
        let absent = "HammerdeckAbsentProbe-\(ProcessInfo.processInfo.processIdentifier)"
        XCTAssertFalse(Native.appIsRunning(named: absent), "the probe name must not exist")

        let t0 = Date()
        let result = Native.shared.runAppleScript(
            "tell application \"\(absent)\" to return 1",
            requiring: absent, timeout: 2, label: "absent probe")
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertNil(result, "an absent target answers nil")
        XCTAssertLessThan(elapsed, 0.1,
                          "the nil came from the liveness gate, not from a script run")
    }

    /// The chokepoint only holds if everything goes through it. A new `tell` added
    /// with bare NSAppleScript would be unbounded and un-gated again -- the exact
    /// 2026-07-23 shape -- and nothing else in the build would notice. Same idea as
    /// the platform's other structural guards (feature_requires, i18n parity).
    func testNoBareNSAppleScriptOutsideTheChokepoint() throws {
        let dir = TestHost.repoRoot + "/app/platform/swift"
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".swift") && $0 != "Native+AppleScript.swift" }
        XCTAssertFalse(files.isEmpty, "found no Swift seam files to scan -- bad path")

        var offenders: [String] = []
        for f in files {
            let text = try String(contentsOfFile: dir + "/" + f, encoding: .utf8)
            if text.contains("NSAppleScript(") { offenders.append(f) }
        }
        XCTAssertEqual(offenders, [],
                       "these bypass Native.runAppleScript (no liveness gate, no timeout ceiling)")
    }

    /// Outbound HTTP has exactly ONE egress point (Native.httpTask, in
    /// Native+Network) and everything -- features AND the host's own config UI --
    /// goes through it. SettingsStore used to open its own URLSession to validate an
    /// OpenAI key, which made the host an exception to the rule the architecture
    /// rests on and put a second network path outside the seam where nothing audits
    /// it. Same structural-guard shape as the NSAppleScript check above: the
    /// chokepoint only holds if nothing new quietly steps around it.
    func testNoURLSessionOutsideTheNetworkSeam() throws {
        let dir = TestHost.repoRoot + "/app/platform/swift"
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".swift") && $0 != "Native+Network.swift" }
        XCTAssertFalse(files.isEmpty, "found no Swift seam files to scan -- bad path")

        var offenders: [String] = []
        for f in files {
            let text = try String(contentsOfFile: dir + "/" + f, encoding: .utf8)
            if text.contains("URLSession.shared") || text.contains("URLSession(") {
                offenders.append(f)
            }
        }
        XCTAssertEqual(offenders, [],
                       "these open their own network egress instead of Native.httpTask")
    }

    /// Every effect kind the Lua engine offers must have a row in the Swift table.
    ///
    /// The two halves are independent: effects.lua's EFFECT_KINDS decides what the
    /// ENGINE can run, RuleEffectKinds decides what the EDITOR can build and load.
    /// Adding a kind to Lua and forgetting the Swift row is the exact failure CODE-4
    /// set out to make impossible -- and it is silent: the kind appears in the "Do"
    /// dropdown (the catalog comes from Lua), then serializes to a command-shaped
    /// dict and quietly does the wrong thing. Nothing in the build notices.
    ///
    /// "command" is excluded on both sides: it is not a fixed kind but a
    /// feature+action pair resolved from the live catalog.
    @MainActor
    func testEveryEngineEffectKindHasAnEditorRow() throws {
        let raw = try TestHost.shared.lua.eval("""
            local ks = {}
            for _, e in ipairs(require("platform.effects").catalog()) do
                if e.kind ~= "command" then ks[#ks+1] = e.kind end
            end
            table.sort(ks)
            return ks
            """)
        let engineKinds = (raw as? [Any])?.compactMap { $0 as? String } ?? []
        XCTAssertFalse(engineKinds.isEmpty, "read no effect kinds from Lua -- bad path, not a pass")

        let missing = engineKinds.filter { EffectKinds.spec(for: $0) == nil }
        XCTAssertEqual(missing, [],
                       "these effect kinds exist in effects.lua but have no row in "
                       + "RuleEffectKinds -- the rule editor cannot build or load them")
    }

    /// Every capability Lua can grant must have real presentation here.
    ///
    /// Enforcement lives in Lua (manifest.CAPABILITY_METHODS); the Swift table in
    /// FeatureChrome is presentation only, so the two can drift -- and the drift is
    /// silent by design: an unknown capability falls back to its raw id and a
    /// generic line, which renders SOMETHING rather than vanishing (showing less
    /// reach than a feature actually has would be the worst failure here). That
    /// fallback is a safety net, not an acceptable resting state: "Files" with a
    /// real sentence is the product, "Newtier / An additional capability." is a
    /// bug the user would never report. This catches it at build time.
    @MainActor
    func testEveryCapabilityHasHostPresentation() throws {
        let raw = try TestHost.shared.lua.eval("""
            local caps = {}
            for c in pairs(require("platform.manifest").KNOWN_CAPABILITIES) do caps[#caps+1] = c end
            table.sort(caps)
            return caps
            """)
        let caps = (raw as? [Any])?.compactMap { $0 as? String } ?? []
        XCTAssertFalse(caps.isEmpty, "read no capabilities from Lua -- bad path, not a pass")

        // capabilityPresentation returns nil for "no wording in this build" -- a
        // direct answer, not a guess at whether the fallback was used.
        let unpresented = caps.filter { capabilityPresentation($0) == nil }
        XCTAssertEqual(unpresented, [],
                       "these capabilities exist in Lua but have no label/glyph/description "
                       + "in capabilityInfo -- they would render as a bare id to the user")
    }

    /// runJXA must DRAIN stdout concurrently. Reading only after termination
    /// deadlocks once osascript's output passes the ~64KB pipe buffer: it blocks in
    /// write(), never exits, the callback never fires -> a wedged st.refreshing and
    /// a switcher stuck on "Loading..." forever. ~200KB is well past the buffer. No
    /// browser / TCC -- the fixed self-test script just emits N bytes. This HANGS
    /// (times out) against the old read-after-termination runJXA; it completes here.
    func testRunJXALargeOutputDoesNotDeadlock() {
        let done = expectation(description: "runJXA returns a >64KB payload without deadlock")
        let box = TestIntBox()
        Native.shared.runJXASelfTest(bytes: 200_000) { n in box.set(n); done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(box.get(), 200_000,
                       "the full payload returns -- the concurrent pipe drain avoided the deadlock")
    }

    /// FIDELITY ANCHOR (opt-in, real Chrome): the fast Lua suite models tab focus
    /// against a FAKE adapter; this proves the real JXA half matches that model --
    /// id-first re-resolution finds the intended tab and returns its live url, and a
    /// non-existent id resolves to nil ("moved"). Gated behind HAMMERDECK_UI_TESTS;
    /// skipped when Chrome is not running / lists no id-bearing tab (it scripts a real
    /// browser: fronts it + first-run Automation TCC prompt).
    ///
    /// The target is chosen ENTIRELY from the bridge's own JXA listing (the same
    /// source `browser_focus_tab` resolves against), and correctness is asserted by
    /// the returned live url -- NOT by cross-checking `browserActiveURL`, which reads
    /// via AppleScript and can disagree with JXA about which windows/tabs exist (Web
    /// Store popups, externally-scripted windows). We also deliberately do NOT create
    /// a throwaway window: a window made in a separate AppleScript process is not
    /// enumerated by a later JXA `app.windows()`. Both quirks bite only test SETUP --
    /// production lists AND focuses through the one JXA path, so it stays consistent.
    func testBrowserTabFocusByIdRealChrome() throws {
        try requireUITests()
        try XCTSkipUnless(
            eval("return require('platform.adapter').isAppRunning('Google Chrome')") as? Bool == true,
            "Google Chrome is not running")

        // List via the bridge; take the first tab that carries a stable Chrome id.
        eval("""
            _G.itTabs = nil
            require('platform.adapter').browserListTabs('Google Chrome', function(tabs)
              _G.itTabs = require('platform.json').encode(tabs or {})
            end)
            return true
            """)
        waitUntil(15.0) { eval("return _G.itTabs") != nil }
        guard let raw = eval("return _G.itTabs") as? String,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !arr.isEmpty else {
            return XCTFail("browserListTabs returned no parseable result")
        }
        let ids = arr.compactMap { ($0["id"] as? NSNumber)?.intValue }
        guard let target = arr.first(where: {
                  (($0["id"] as? NSNumber)?.intValue ?? 0) > 0 && !(($0["url"] as? String) ?? "").isEmpty
              }),
              let targetId = (target["id"] as? NSNumber)?.intValue,
              let targetUrl = target["url"] as? String else {
            throw XCTSkip("Chrome lists no id-bearing tab to target")
        }

        // 1. Focus that tab BY ITS ID (url arg is ignored on the id path -> ''): the
        //    real bridge must resolve to THAT tab and return its live url. A wrong
        //    resolution (the positional bug) would return a different tab's url.
        eval("""
            _G.itFocus = false
            require('platform.adapter').browserFocusTab('Google Chrome', \(targetId), 0, '', 0,
              function(u) _G.itFocus = u or false end)
            return true
            """)
        // Seeded `false`, and the callback writes `u or false` -- so "no longer
        // false" cannot tell "not yet fired" from "fired with nil". Wait for a
        // STRING instead: a nil result then burns the ceiling and fails on the
        // equality below, which is the honest outcome for a broken resolve.
        waitUntil(15.0) { eval("return _G.itFocus") as? String != nil }
        XCTAssertEqual(eval("return _G.itFocus") as? String, targetUrl,
                       "focus-by-id resolves to the intended tab and returns its live url")

        // 2. Focus an id that cannot exist (max + 1000): no match -> nil ("moved").
        let bogus = (ids.max() ?? 0) + 1000
        eval("""
            _G.itGone = 'unset'
            require('platform.adapter').browserFocusTab('Google Chrome', \(bogus), 0, '', 0,
              function(u) _G.itGone = u end)
            return true
            """)
        // nil IS the expected answer here, so the wait CANNOT be "non-nil" -- that
        // would return instantly and assert nothing. The `'unset'` seed above is
        // what makes the difference observable: wait for it to stop being the
        // sentinel, i.e. for the callback to have actually run. Keep that seed --
        // without it, a callback that never fires would leave nil and pass.
        waitUntil(15.0) { eval("return _G.itGone") as? String != "unset" }
        XCTAssertNil(eval("return _G.itGone"), "a non-existent tab id resolves to nil (moved)")

        eval("_G.itTabs = nil; _G.itFocus = nil; _G.itGone = nil; return true")
    }

    /// FIDELITY ANCHOR (opt-in, real Safari): Safari tabs have NO stable id, so
    /// browser_focus_tab resolves by URL (winId is the tie-break hint) and activates
    /// via `win.currentTab = tab`. This is the ONE path the Chrome anchor can't cover,
    /// and the "activation honesty" fix now surfaces a `currentTab` quirk LOUDLY as a
    /// nil ("moved") -- so this test is the guard that Safari jumps actually land.
    /// Gated; skipped when Safari is not running. Target + focus happen in Lua (no
    /// url string escaping across the eval boundary).
    func testBrowserTabFocusByUrlRealSafari() throws {
        try requireUITests()
        try XCTSkipUnless(
            eval("return require('platform.adapter').isAppRunning('Safari')") as? Bool == true,
            "Safari is not running")

        // List, then (all in Lua) pick the first tab with a url and re-focus it BY URL
        // -- tabId 0 forces the url path, exactly as a real Safari pick does.
        eval("""
            _G.sfTarget = nil
            _G.sfLanded = 'unset'
            _G.sfListed = false
            require('platform.adapter').browserListTabs('Safari', function(tabs)
              _G.sfListed = true
              for _, t in ipairs(tabs or {}) do
                if t.url and t.url ~= '' then
                  _G.sfTarget = t.url
                  require('platform.adapter').browserFocusTab('Safari', 0, t.winId or 0, t.url,
                    t.tabIndex or 0, function(u) _G.sfLanded = u or false end)
                  return
                end
              end
            end)
            return true
            """)
        // Two chained async steps (list -> focus), so "settled" is not one flag:
        // wait until the LIST callback ran and, if it found a target, the FOCUS
        // callback ran too. Polling only for sfLanded would burn the full ceiling
        // on a Safari with no url-bearing tab (a legitimate skip, below); polling
        // only for sfListed would race the focus step and read a stale 'unset'.
        // `_G.sfListed` exists solely to make the no-target path observable.
        //
        // This test used to fail about half the time, and the cause was NOT here
        // and not in Safari: runJXACore held no strong reference to the child's
        // Pipe, so Process deallocated at child exit and closed the read end while
        // the readability source was still racing to deliver EOF. The stdout
        // obligation then never completed and the pinned Lua callback was dropped
        // for good. Fixed by retaining the pipes to completion (Native+Browser,
        // JXAPipes) -- measured 69 losses in 150 runs without, 0 with. This
        // ceiling is only a liveness bound now, sized for the fast case (the whole
        // chain settles in well under a second) rather than for a reply that is
        // never coming.
        waitUntil(10.0) {
            eval("return _G.sfListed == true and (_G.sfTarget == nil or _G.sfLanded ~= 'unset')")
                as? Bool == true
        }
        guard let target = eval("return _G.sfTarget") as? String else {
            throw XCTSkip("Safari lists no tab with a url to target")
        }
        // The crux: url-resolution + `win.currentTab = tab` must return the tab's live
        // url. If currentTab assignment throws, activation honesty returns {} -> nil
        // here -- catching a fully-broken Safari path.
        XCTAssertEqual(eval("return _G.sfLanded") as? String, target,
                       "Safari focus-by-url resolves + activates the tab and returns its url")

        // A url that matches no Safari tab -> nil ("moved").
        eval("""
            _G.sfGone = 'unset'
            require('platform.adapter').browserFocusTab('Safari', 0, 0,
              'https://hammerdeck-no-such-safari-tab.invalid/', 0, function(u) _G.sfGone = u end)
            return true
            """)
        // Same sentinel rule as itGone above: nil is the expected answer, so wait
        // for the seed to be replaced, not for a non-nil value.
        waitUntil(15.0) { eval("return _G.sfGone") as? String != "unset" }
        XCTAssertNil(eval("return _G.sfGone"), "an unmatched url resolves to nil (moved)")

        eval("_G.sfTarget = nil; _G.sfLanded = nil; _G.sfGone = nil; _G.sfListed = nil; return true")
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
        // WAIT FOR THE CALLBACK, don't sleep a fixed budget. This test used
        // `spinRunLoop(3.0)` -- a flat 3s sleep -- for work that copies Chrome's
        // Favicons SQLite DB aside (4.9MB on this machine) and queries it. That
        // raced, and failed 1 run in 3 in isolation on 2026-07-24; it is near
        // certainly the earlier one-off nobody could reproduce, since the pipe to
        // `grep` had thrown away its name.
        //
        // The evidence is the timings AFTER this fix, not before: a fixed sleep
        // always burns its full budget, so the old ~3.1s case duration measured
        // the sleep, not the work. Polling, the same work lands in 1.0-4.5s run
        // to run -- and that 4.5s run is the proof, because it would have blown
        // the old 3.0s budget outright.
        //
        // No budget can be "right" here: it scales with machine load and with how
        // much the USER has browsed, neither of which the test controls. So poll
        // and exit the moment the result lands; the ceiling below is only a
        // liveness bound, not a race. (A genuine hang still fails, on the
        // assertion underneath, with the right message.)
        _ = waitUntil(15.0) { eval("return _G.itFav") != nil }
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

    /// The sticky-modifier fix: a chord's follow key must fire whether or not the
    /// user released the leader mods -- Hyper is a HELD combo, so "Hyper+M then M/C"
    /// naturally keeps them down on the follow. Covers BOTH halves: a DIFFERENT
    /// follow key held-leader (the sticky twin bound at the prefix mods) and the
    /// SAME key as the prefix held-leader (prefixPressed advances vs re-arming).
    func testChordStickyModifiersFollowLeaderHeld() throws {
        try requireUITests()
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        host.store.setEnabled("plain_paste", true)
        UserDefaults.standard.removeObject(forKey: "hammerdeck.opt.plain_paste.mode")

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            host.store.clearTrigger("plain_paste", "main")
            host.store.setEnabled("plain_paste", false)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: Int, down: Bool, flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        // Press ⌘⇧ and the prefix A, leaving ⌘⇧ STILL held down.
        func armLeaderHeld() {
            key(kVK_Command, down: true, flags: [.maskCommand])
            key(kVK_Shift, down: true, flags: [.maskCommand, .maskShift])
            key(kVK_ANSI_A, down: true, flags: [.maskCommand, .maskShift])
            key(kVK_ANSI_A, down: false, flags: [.maskCommand, .maskShift])
        }
        func pressHeld(_ code: Int) {
            key(code, down: true, flags: [.maskCommand, .maskShift])
            key(code, down: false, flags: [.maskCommand, .maskShift])
        }
        func releaseLeader() {
            key(kVK_Shift, down: false, flags: [.maskCommand])
            key(kVK_Command, down: false, flags: [])
        }
        func chordRan() -> Bool {
            for _ in 0..<16 {
                pumpAppEvents(0.05)
                if pb.string(forType: .string) == "padded text" { return true }
            }
            return false
        }

        // Half 1 -- DIFFERENT follow key, leader held (⌘⇧A then ⌘⇧B): the sticky
        // twin bound at ⌘⇧+B fires the advance.
        XCTAssertNil(host.store.setTrigger("plain_paste", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["b"])))
        pb.clearContents(); pb.setString("  padded text  ", forType: .string)
        armLeaderHeld()
        pumpAppEvents(0.4)                 // let arm() register the bare + sticky follow twins
        pressHeld(kVK_ANSI_B)              // B with ⌘⇧ STILL held
        releaseLeader()
        XCTAssertTrue(chordRan(),
            "a different follow key pressed leader-held (⌘⇧A then ⌘⇧B) still fires the chord")

        // Half 2 -- SAME key as the prefix, leader held (⌘⇧A then ⌘⇧A): the exact
        // re-press of the prefix combo advances (there is no follow twin for it).
        XCTAssertNil(host.store.setTrigger("plain_paste", "main",
            TriggerSpec(type: "chord", mods: ["cmd", "shift"], key: "a", follows: ["a"])))
        pb.clearContents(); pb.setString("  padded text  ", forType: .string)
        armLeaderHeld()
        pumpAppEvents(0.4)
        pressHeld(kVK_ANSI_A)              // the SECOND ⌘⇧A = the follow key
        releaseLeader()
        XCTAssertTrue(chordRan(),
            "the same key as the prefix pressed leader-held (⌘⇧A then ⌘⇧A) advances and fires")
    }

    /// The park/restore primitive a modal's "sticky" keys use to SHADOW a
    /// standalone hotkey on their combo (e.g. window_grid's 2×2 mode shadowing a
    /// standalone "Hyper+1" while the mode is live, so a leader-held "1" lands the
    /// cell instead of firing the global). While parked the combo must not reach
    /// its handler; after restore it must fire again. Proves the mechanism the
    /// sticky-modifier fix leans on, independent of the modal/feature stack --
    /// this is the half that was red before the fix (the key leaked to the global).
    func testHotkeyParkShadowsAndRestores() throws {
        try requireUITests()
        try XCTSkipUnless(canDeliverSynthesizedHotkeys(),
            "this environment cannot deliver synthesized hotkeys (grant Accessibility to the terminal running `swift test`)")

        var fires = 0
        guard let unbind = HotkeyCenter.shared.bind(mods: ["cmd", "shift"], key: "b",
                                                    handler: { fires += 1 }) else {
            return XCTFail("could not register the standalone ⌘⇧B")
        }
        defer { unbind() }

        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_B), keyDown: down)
            e?.flags = [.maskCommand, .maskShift]
            e?.post(tap: .cghidEventTap)
        }
        func pressCmdShiftB() { key(true); key(false); pumpAppEvents(0.3) }

        pressCmdShiftB()
        XCTAssertEqual(fires, 1, "the standalone ⌘⇧B should fire before parking")

        let restore = HotkeyCenter.shared.park(key: "b", mods: ["cmd", "shift"])
        pressCmdShiftB()
        XCTAssertEqual(fires, 1, "a parked combo must be shadowed -- its handler must not fire")

        restore()
        pressCmdShiftB()
        XCTAssertEqual(fires, 2, "restore must re-register the shadowed hotkey so it fires again")
    }

    // MARK: - Seam token strictness

    /// Unknown string tokens must fail LOUDLY at the native seam, never fall
    /// into a silent default -- the class of bug where window_snap's
    /// "previous" fell through adjacentScreen's `dir == "prev"` to "next".
    /// A silently-dropped modifier binds or synthesizes a LESS-modified combo;
    /// an unknown appearance mode used to silently toggle; an unknown
    /// held-modifier probe read as "never held". Every rejected call here
    /// fails BEFORE its side effect (no registration, no CGEvent, no
    /// AppleScript), so this is Tier 1 -- safe everywhere.
    func testSeamRejectsUnknownTokensLoudly() {
        let cases: [(String, String)] = [
            ("native.bind_hotkey({'cmmd'}, 'k', function() end)", "bind_hotkey"),
            ("native.bind_chord({'hyper'}, 'a', {'b'}, function() end)", "bind_chord"),
            ("native.key_stroke({'comd'}, 'v')", "key_stroke"),
            ("native.is_modifier_held('atl')", "is_modifier_held"),
            ("native.set_appearance('drak')", "set_appearance"),
        ]
        for (call, name) in cases {
            let r = eval("local ok, err = pcall(function() \(call) end); "
                + "return ok and 'ok' or tostring(err)") as? String
            XCTAssertNotEqual(r, "ok", "\(name) must reject an unknown token")
            XCTAssertTrue(r?.contains("unknown") == true,
                          "\(name) error should name the bad token -- got \(r ?? "nil")")
        }
        // Non-string mods entries are the same bug through a side door:
        // stringArray filters them out before the token gate, so the seam
        // also checks the raw table length survived the read.
        let nonString = eval("local ok, err = pcall(function() native.key_stroke({true}, 'v') end); "
            + "return ok and 'ok' or tostring(err)") as? String
        XCTAssertTrue(nonString?.contains("modifier name strings") == true,
                      "non-string mods must be rejected -- got \(nonString ?? "nil")")

        // The long aliases stay valid through the same gate: 'command'+'option'
        // registers (obscure combo, unbound immediately).
        let id = eval("return native.bind_hotkey({'command','option','ctrl'}, 'f19', function() end)")
            as? Double
        XCTAssertNotNil(id, "long modifier aliases must still bind (numeric resource id)")
        if let id {
            eval("native.stop(\(Int(id))); return true")   // never leak the registration
        }
    }

    /// The fake adapter mirrors the seam's modifier whitelist by hand -- pin
    /// the two together so the headless suite rejects exactly what the real
    /// bridge rejects. (triggers.validate needs no pin: it reads the live
    /// adapter's validModifiers, so it follows whichever side is loaded.)
    func testFakeAdapterModifierWhitelistMatchesSeam() {
        let real = eval("return table.concat(native.valid_modifiers(), ',')") as? String
        let fake = eval("local f = dofile('\(TestHost.repoRoot)/test/fake_adapter.lua'); "
            + "return table.concat(f.adapter.validModifiers(), ',')") as? String
        XCTAssertNotNil(real, "native.valid_modifiers must return the token list")
        XCTAssertEqual(real, fake,
                       "fake_adapter's modifier whitelist must equal KeyModifier.validTokens")
    }
}
