import XCTest
@testable import HammerdeckKit

// The opt-in feature statistics an update check carries. What must hold: no field
// leaves the Mac while sharing is off -- whatever the Lua side answers -- and the
// fields that do go out carry exactly the four kinds of data the user agreed to. The delegate's
// selector is asserted on the wiring, as UpdaterDelegateTests does for its others:
// an unmatched optional SPUUpdaterDelegate method compiles and is never called.
@MainActor
final class FeatureStatsTests: XCTestCase {

    private let keys = [FeatureStats.shareKey, FeatureStats.idKey,
                        FeatureStats.askedKey, FeatureStats.countsKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        // The test bundle's defaults domain is xctest's, not the app's; restore
        // anyway so these tests never depend on order.
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private let os27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
    private let full: [String: Any] = ["on": "window_deck,window_grid",
                                       "day": "2026-10-07", "use": "window_deck:2"]

    private func fields(_ p: [[String: String]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: p.map { ($0["key"]!, $0["value"]!) })
    }

    func testTheDelegateRespondsToTheFeedParametersSelector() {
        let responds = UpdaterDelegate().responds(
            to: Selector(("feedParametersForUpdater:sendingSystemProfile:")))
        XCTAssertTrue(responds, "unmatched, the switch would flip and no update check would carry anything")
    }

    func testNothingIsSentWhileSharingIsOff() {
        // Even if the Lua side answered (it would not), Swift's own gate holds.
        XCTAssertEqual(FeatureStats.parameters(osVersion: os27, report: { self.full }), [])
        XCTAssertNil(UserDefaults.standard.string(forKey: FeatureStats.idKey),
                     "no install ID is even made before the user says yes")
    }

    func testTheAgreedFieldsAndNothingElseWhenSharing() {
        FeatureStats.setSharing(true)
        let f = fields(FeatureStats.parameters(osVersion: os27, report: { self.full }))
        XCTAssertEqual(Set(f.keys), ["hd_id", "hd_os", "hd_on", "hd_day", "hd_use"])
        XCTAssertEqual(f["hd_os"], "27.0", "major.minor only")
        XCTAssertEqual(f["hd_on"], "window_deck,window_grid")
        XCTAssertEqual(f["hd_day"], "2026-10-07")
        XCTAssertEqual(f["hd_use"], "window_deck:2")
        XCTAssertNotNil(UUID(uuidString: f["hd_id"] ?? ""), "the ID is a random UUID")
    }

    func testNoDayFieldsBeforeACompleteDayExists() {
        FeatureStats.setSharing(true)
        let f = fields(FeatureStats.parameters(osVersion: os27, report: { ["on": "window_deck"] }))
        XCTAssertEqual(Set(f.keys), ["hd_id", "hd_os", "hd_on"])
    }

    func testTheIDIsStableUntilReset() {
        FeatureStats.setSharing(true)
        let first = fields(FeatureStats.parameters(osVersion: os27, report: { self.full }))["hd_id"]
        let again = fields(FeatureStats.parameters(osVersion: os27, report: { self.full }))["hd_id"]
        XCTAssertEqual(first, again, "one copy keeps one ID across checks")
        UserDefaults.standard.set("{}", forKey: FeatureStats.countsKey)
        FeatureStats.resetID()
        let reset = fields(FeatureStats.parameters(osVersion: os27, report: { self.full }))["hd_id"]
        XCTAssertNotEqual(first, reset, "Reset ID makes a new one")
        XCTAssertNil(UserDefaults.standard.object(forKey: FeatureStats.countsKey),
                     "and the new ID does not inherit the old counts")
    }

    func testTurningSharingOffDropsTheCountsAndCountsAsAnswered() {
        FeatureStats.setSharing(true)
        UserDefaults.standard.set("{}", forKey: FeatureStats.countsKey)
        FeatureStats.setSharing(false)
        XCTAssertNil(UserDefaults.standard.object(forKey: FeatureStats.countsKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: FeatureStats.idKey),
                     "the ID is forgotten, so sharing again later starts an unlinked copy")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: FeatureStats.askedKey),
                      "a user who decided in Settings is never asked again")
        XCTAssertEqual(FeatureStats.parameters(osVersion: os27, report: { self.full }), [])
    }

    func testAReportThatFailsSendsNothing() {
        FeatureStats.setSharing(true)
        struct Broken: Error {}
        XCTAssertEqual(FeatureStats.parameters(osVersion: os27, report: { throw Broken() }), [],
                       "not even the ID goes out when the report cannot be read")
    }

    // Every other case injects the report. This one crosses the real bridge:
    // registry.statsReport's Lua table must arrive as [String: Any], or every
    // opted-in check would quietly carry nothing.
    func testTheRealBridgeReportArrivesWhenSharing() {
        _ = TestHost.shared          // boot first: its init clears hammerdeck.* keys
        FeatureStats.setSharing(true)
        let f = fields(FeatureStats.parameters(osVersion: os27))
        XCTAssertNotNil(f["hd_on"], "the Lua report crossed the bridge")
        XCTAssertNotNil(f["hd_id"])
        XCTAssertEqual(f["hd_os"], "27.0")
        FeatureStats.setSharing(false)
        XCTAssertEqual(FeatureStats.parameters(osVersion: os27), [], "and off sends nothing")
    }
}
