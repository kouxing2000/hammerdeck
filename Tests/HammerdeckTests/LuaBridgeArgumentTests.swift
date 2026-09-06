// LuaBridgeArgumentTests -- the bridge's argument readers and callback pinning.
//
// These sit on `LuaState` rather than on the panel functions that motivated
// them. Both defects are in how the BRIDGE reads a missing value, and every
// `Native+*` slice reads through the same two helpers -- a test that drove
// `deck_widget_show` would prove one caller right and stay green when the next
// one repeats the mistake. It would also need a real panel on screen, which
// puts it behind the UI opt-in and out of CI.

import XCTest
@testable import HammerdeckKit
import CLua

final class LuaBridgeArgumentTests: XCTestCase {

    private var lua: LuaState!

    override func setUp() {
        super.setUp()
        lua = LuaState()
    }

    override func tearDown() {
        lua = nil
        super.tearDown()
    }

    /// Push one Lua value described by `expr` and hand its stack index to `body`.
    private func withPushed(_ expr: String, _ body: (Int32) -> Void) {
        XCTAssertEqual(luaL_loadstring(lua.L, "return " + expr), LUA_OK,
                       "fixture `\(expr)` failed to compile")
        XCTAssertEqual(lua_pcallk(lua.L, 0, 1, 0, 0, nil), LUA_OK,
                       "fixture `\(expr)` failed to run")
        body(-1)
        lua_settop(lua.L, -2)
    }

    // MARK: - H-7: absent is not false

    func testBoolDistinguishesAbsentFromFalse() {
        withPushed("false") { XCTAssertEqual(LuaState.bool(lua.L, $0), false) }
        withPushed("true") { XCTAssertEqual(LuaState.bool(lua.L, $0), true) }

        // The whole point: nil and a slot past the top must read as "not given",
        // or `?? true` is dead code and an omitted flag silently defaults false.
        withPushed("nil") { XCTAssertNil(LuaState.bool(lua.L, $0)) }
        XCTAssertNil(LuaState.bool(lua.L, 99), "a slot past the top is absent, not false")

        // Lua truthiness still governs what IS present -- only `false` is false.
        // A reader that answered nil for 0 or "" would break every caller that
        // passes a number where a flag is expected.
        withPushed("0") { XCTAssertEqual(LuaState.bool(lua.L, $0), true) }
        withPushed("''") { XCTAssertEqual(LuaState.bool(lua.L, $0), true) }
    }

    func testAnOmittedFlagTakesTheDocumentedDefault() {
        // The shape every panel field reader uses. Before the fix this line
        // could not compile against a non-optional `bool`, so the `true` was
        // dead and `heroOn` came back false on an omitted field -- a deck
        // opening with Hero off despite the documented default.
        withPushed("nil") {
            XCTAssertTrue(LuaState.bool(lua.L, $0) ?? true, "the ?? default must actually apply")
        }
        withPushed("false") {
            XCTAssertFalse(LuaState.bool(lua.L, $0) ?? true, "an EXPLICIT false must still win")
        }
    }

    // MARK: - H-8: an omitted callback is not a callback

    func testMakeCallbackRefRefusesAbsentAndNonFunctions() {
        var logged: [String] = []
        lua.errorSink = { logged.append($0) }

        withPushed("nil") {
            XCTAssertEqual(lua.makeCallbackRef(at: $0, named: "onMove"), LUA_REFNIL)
        }
        XCTAssertEqual(logged, [], "an ABSENT optional callback is normal -- it must not log")

        withPushed("'not a function'") {
            XCTAssertEqual(lua.makeCallbackRef(at: $0, named: "onExit"), LUA_REFNIL,
                           "a present-but-uncallable value is refused, not pinned")
        }
        XCTAssertEqual(logged.count, 1, "...but a wiring mistake earns exactly one line")
        XCTAssertTrue(logged[0].contains("onExit"),
                      "and that line names the field: \(logged[0])")

        withPushed("function() end") {
            let ref = lua.makeCallbackRef(at: $0, named: "onSwitch")
            XCTAssertGreaterThan(ref, 0, "a real function still pins a real registry ref")
            lua.releaseRef(ref)
        }
    }

    func testCallRefIgnoresEveryNoCallbackSentinel() {
        var logged: [String] = []
        lua.errorSink = { logged.append($0) }

        // Assert the LANDMARK first: prove `errorSink` is the sink callRef
        // actually uses, or the silence below is unfalsifiable -- reroute
        // callRef's errors anywhere else and every assertion here stays green
        // while each sentinel logs once per event.
        XCTAssertEqual(luaL_loadstring(lua.L, "return function() error('boom') end"), LUA_OK)
        XCTAssertEqual(lua_pcallk(lua.L, 0, 1, 0, 0, nil), LUA_OK)
        let raising = lua.makeCallbackRef(at: -1, named: "onExit")
        lua_settop(lua.L, -2)
        lua.callRef(raising)
        XCTAssertEqual(logged.count, 1, "a REAL callback error must reach this sink")
        XCTAssertTrue(logged[0].contains("boom"), logged[0])
        lua.releaseRef(raising)
        logged.removeAll()

        // -1 (LUA_REFNIL, from an absent field), -2 (LUA_NOREF) and 0 (the
        // sentinel Native+Triggers uses for an absent release handler) all mean
        // "nobody is listening". Calling any of them reached lua_pcallk with nil
        // on the stack and logged an error PER EVENT -- once per mouse-move on a
        // drag handler.
        for sentinel: Int32 in [LUA_REFNIL, LUA_NOREF, 0] {
            lua.callRef(sentinel)
        }
        XCTAssertEqual(logged, [], "no sentinel may reach Lua: \(logged)")
    }

    func testARequiredCallbackThatIsNilSaysSoAtCreation() {
        var logged: [String] = []
        lua.errorSink = { logged.append($0) }

        // `makeRef` is the REQUIRED path -- ~24 bindings (hotkeys, timers, HTTP,
        // watchers) call it for a handler they cannot work without. Since callRef
        // now refuses a non-positive ref, a nil here would otherwise be wholly
        // silent: `bind_hotkey` would still grab the combo globally, every press
        // would do nothing, and the daily log would be empty. Before the refusal
        // existed, the first press at least announced itself.
        withPushed("nil") {
            XCTAssertLessThanOrEqual(lua.makeRef(at: $0), 0, "a nil pins nothing")
        }
        XCTAssertEqual(logged.count, 1, "...and it must not do that quietly")
        XCTAssertTrue(logged[0].contains("required callback"), logged[0])
        XCTAssertTrue(logged[0].contains("LuaBridgeArgumentTests"),
                      "the line must name the CALL SITE, not this function: \(logged[0])")

        // The optional path stays quiet through the same machinery -- otherwise
        // the fix for one trades straight into noise for the other.
        logged.removeAll()
        withPushed("nil") { _ = lua.makeCallbackRef(at: $0, named: "onMove") }
        XCTAssertEqual(logged, [], "an omitted OPTIONAL callback is still silent")
    }

    func testTheLeakCounterStaysSymmetricAcrossAnOmittedCallback() {
        // `makeRef` counts only what it pinned, so `releaseRef` must skip what it
        // never pinned. An unconditional decrement drives the count BELOW
        // baseline, and a negative drift cancels a real leak -- the detector then
        // reads green on exactly the bug it exists to catch. Both existing tests
        // that read this counter are behind the UI opt-in and skipped in CI, so
        // this is the only place the asymmetry can surface.
        #if DEBUG
        let baseline = lua.pinnedRefCount
        for _ in 0..<3 {
            withPushed("nil") { lua.releaseRef(lua.makeCallbackRef(at: $0, named: "onMove")) }
        }
        XCTAssertEqual(lua.pinnedRefCount, baseline,
                       "an omitted callback must move the counter in neither direction")

        withPushed("function() end") {
            let ref = lua.makeCallbackRef(at: $0, named: "onMove")
            XCTAssertEqual(lua.pinnedRefCount, baseline + 1, "a real pin still counts")
            lua.releaseRef(ref)
        }
        XCTAssertEqual(lua.pinnedRefCount, baseline, "and still balances on release")
        #endif
    }

    func testCallRefStillCallsARealCallback() {
        // The guard must not be so wide that it swallows working callbacks --
        // an over-eager `guard` here would silence every panel in the app and
        // every assertion above would still pass.
        XCTAssertEqual(luaL_loadstring(lua.L, "hits = 0; return function(n) hits = hits + n end"),
                       LUA_OK)
        XCTAssertEqual(lua_pcallk(lua.L, 0, 1, 0, 0, nil), LUA_OK)
        let ref = lua.makeCallbackRef(at: -1, named: "onSwitch")
        lua_settop(lua.L, -2)

        lua.callRef(ref) { L in lua_pushinteger(L, 7); return 1 }
        lua.callRef(ref) { L in lua_pushinteger(L, 5); return 1 }
        XCTAssertEqual(try? lua.eval("return hits") as? Double, 12,
                       "a pinned function is invoked with its arguments, every time")
        lua.releaseRef(ref)
    }
}
