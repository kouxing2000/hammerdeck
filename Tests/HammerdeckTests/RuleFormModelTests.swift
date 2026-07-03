import XCTest
@testable import HammerdeckKit

/// Unit tests for the rule-form SERIALIZER (RuleFormModel.buildSpec), extracted
/// out of the AddRuleForm SwiftUI view in P12 so it's testable at all. buildSpec
/// turns the form's state into the engine's rule-spec dict; a bug here silently
/// persists a malformed rule, so the subtle paths (bundle-id gating, required
/// fields, incomplete-step dropping) earn the coverage.
final class RuleFormModelTests: XCTestCase {

    /// A realistic option catalog: a spread of effect kinds + two signals, one
    /// that matches by bundle id (frontmostApp) and one that does not (powerSource).
    private func makeOpts() -> RuleFormOptions {
        RuleFormOptions([
            "effects": [
                ["kind": "notify", "label": "Notify"],
                ["kind": "layout", "label": "Arrange windows"],
                ["kind": "launchApp", "label": "Open an app"],
                ["kind": "minimizeApp", "label": "Minimize an app"],
                ["kind": "chain", "label": "Do several things"],
                ["kind": "setAppearance", "label": "Set appearance"],
                ["kind": "volume", "label": "Volume"],
                ["kind": "mediaKey", "label": "Media key"],
                ["kind": "command", "label": "Run Foo", "feature": "foo", "action": "go"],
            ],
            "signalMeta": [
                "frontmostApp": ["label": "frontmost app", "bundleIdMatch": true],
                "powerSource": ["label": "power source", "bundleIdMatch": false],
            ],
        ])
    }

    private func model(_ effectId: String) -> RuleFormModel {
        var m = RuleFormModel()
        m.opts = makeOpts()
        m.effectId = effectId
        return m
    }

    private func on(_ spec: [String: Any]?) -> [String: Any]? { spec?["on"] as? [String: Any] }
    private func effect(_ spec: [String: Any]?) -> [String: Any]? { spec?["effect"] as? [String: Any] }

    func testStateTriggerWithNotify() {
        var m = model("notify")
        m.triggerType = "state:frontmostApp"
        m.transition = "becomes"
        m.stateValue = "Safari"
        m.notifyTitle = "Hi"
        m.notifyText = "body"
        let spec = m.buildSpec()
        XCTAssertEqual(on(spec)?["type"] as? String, "state")
        XCTAssertEqual(on(spec)?["signal"] as? String, "frontmostApp")
        XCTAssertEqual(on(spec)?["becomes"] as? String, "Safari")
        XCTAssertEqual(effect(spec)?["kind"] as? String, "notify")
        XCTAssertEqual(effect(spec)?["title"] as? String, "Hi")
        XCTAssertEqual(effect(spec)?["text"] as? String, "body")
        XCTAssertEqual(effect(spec)?["channel"] as? String, "system")
    }

    func testBundleIdAttachedOnlyForBundleIdSignal() {
        // frontmostApp matches by bundle id -> the id is persisted.
        var m = model("notify")
        m.triggerType = "state:frontmostApp"; m.stateValue = "Safari"
        m.stateValueBundleId = "com.apple.Safari"; m.notifyTitle = "x"
        XCTAssertEqual(on(m.buildSpec())?["bundleId"] as? String, "com.apple.Safari")

        // powerSource does NOT -> the (stale) id must never ride along, or the
        // engine would match a bundle id it can never satisfy = a silent dead rule.
        m.triggerType = "state:powerSource"; m.stateValue = "battery"
        XCTAssertNil(on(m.buildSpec())?["bundleId"],
                     "a non-bundle-id signal must never carry on.bundleId")
    }

    func testEventAndScheduleTriggers() {
        var m = model("notify"); m.notifyTitle = "x"
        m.triggerType = "event"; m.eventName = "wake"
        XCTAssertEqual(on(m.buildSpec())?["event"] as? String, "wake")

        m.triggerType = "schedule"; m.scheduleMode = "everyMin"; m.everyMin = 25
        XCTAssertEqual(on(m.buildSpec())?["everyMin"] as? Int, 25)

        m.scheduleMode = "at"; m.atTime = "09:30"
        XCTAssertEqual(on(m.buildSpec())?["at"] as? String, "09:30")
    }

    func testLaunchAppRequiresBundleId() {
        var m = model("launchApp")
        m.triggerType = "event"; m.eventName = "wake"
        m.launchAppName = "Safari"
        XCTAssertNil(m.buildSpec(), "launchApp with a name but no bundle id is too incomplete")
        m.launchAppBundleId = "com.apple.Safari"
        let eff = effect(m.buildSpec())
        XCTAssertEqual(eff?["kind"] as? String, "launchApp")
        XCTAssertEqual(eff?["app"] as? String, "Safari")
        XCTAssertEqual(eff?["appBundleId"] as? String, "com.apple.Safari")
    }

    func testAppTargetCarriesOptionalBundleId() {
        var m = model("minimizeApp")
        m.triggerType = "event"; m.eventName = "wake"
        m.minimizeAppName = "Mail"
        XCTAssertEqual(effect(m.buildSpec())?["kind"] as? String, "minimizeApp")
        XCTAssertNil(effect(m.buildSpec())?["appBundleId"], "no bundle id -> name-only match")
        m.minimizeAppBundleId = "com.apple.mail"
        XCTAssertEqual(effect(m.buildSpec())?["appBundleId"] as? String, "com.apple.mail")
    }

    func testChainDropsIncompleteSteps() {
        var m = model("chain")
        m.triggerType = "event"; m.eventName = "wake"
        var speak = ChainStep(); speak.kind = "speak"; speak.speakText = "hi"
        var url = ChainStep(); url.kind = "openURL"; url.url = ""   // incomplete -> dropped
        let lock = { var s = ChainStep(); s.kind = "lockScreen"; return s }()
        m.chainSteps = [speak, url, lock]
        let steps = effect(m.buildSpec())?["effects"] as? [[String: Any]]
        XCTAssertEqual(steps?.count, 2, "the incomplete openURL step is dropped, order kept")
        XCTAssertEqual(steps?.first?["kind"] as? String, "speak")
        XCTAssertEqual(steps?.last?["kind"] as? String, "lockScreen")
    }

    func testSystemAtomEffectsCarryTheirEnumParam() {
        // The three demoted-feature atoms each serialize their single enum param.
        var appearance = model("setAppearance")
        appearance.triggerType = "event"; appearance.eventName = "wake"
        appearance.appearanceMode = "light"
        XCTAssertEqual(effect(appearance.buildSpec())?["kind"] as? String, "setAppearance")
        XCTAssertEqual(effect(appearance.buildSpec())?["mode"] as? String, "light")

        var volume = model("volume")
        volume.triggerType = "event"; volume.eventName = "wake"
        volume.volumeOp = "mute"
        XCTAssertEqual(effect(volume.buildSpec())?["kind"] as? String, "volume")
        XCTAssertEqual(effect(volume.buildSpec())?["op"] as? String, "mute")

        var media = model("mediaKey")
        media.triggerType = "event"; media.eventName = "wake"
        media.mediaKeyName = "next"
        XCTAssertEqual(effect(media.buildSpec())?["kind"] as? String, "mediaKey")
        XCTAssertEqual(effect(media.buildSpec())?["key"] as? String, "next")
    }

    func testCommandEffectAndRuleName() {
        var m = model("command:foo.go")
        m.triggerType = "schedule"; m.scheduleMode = "at"; m.atTime = "08:00"
        m.name = "My rule"
        let spec = m.buildSpec()
        XCTAssertEqual(spec?["name"] as? String, "My rule")
        XCTAssertEqual(effect(spec)?["kind"] as? String, "command")
        XCTAssertEqual(effect(spec)?["feature"] as? String, "foo")
        XCTAssertEqual(effect(spec)?["action"] as? String, "go")
    }

    func testIncompleteFormReturnsNil() {
        var m = model("notify")
        m.triggerType = "state:frontmostApp"; m.notifyTitle = "x"
        m.stateValue = ""                      // empty trigger value
        XCTAssertNil(m.buildSpec())
        m.stateValue = "Safari"; m.notifyTitle = "   "   // whitespace-only title
        XCTAssertNil(m.buildSpec())

        var m2 = RuleFormModel()               // no opts -> no selectedEffect
        m2.triggerType = "event"; m2.eventName = "wake"
        XCTAssertNil(m2.buildSpec(), "no resolvable effect -> nil")
    }

    func testLayoutDropsIncompleteAndForksCapturedRatios() {
        var m = model("layout")
        m.triggerType = "event"; m.eventName = "wake"
        var named = Placement(); named.app = "Safari"; named.screen = "Main"; named.pos = "left-half"
        var captured = Placement(); captured.app = "Mail"; captured.screen = "Main"
        captured.pos = capturedPosId; captured.ratios = ["x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0]
        var incomplete = Placement(); incomplete.app = "Notes"; incomplete.screen = ""  // dropped
        m.placements = [named, captured, incomplete]
        let list = effect(m.buildSpec())?["placements"] as? [[String: Any]]
        XCTAssertEqual(list?.count, 2, "the incomplete placement (empty screen) is dropped, order kept")
        XCTAssertEqual(list?[0]["pos"] as? String, "left-half",
                       "a named position serializes as its id string")
        XCTAssertEqual((list?[1]["pos"] as? [String: Double])?["w"], 0.5,
                       "a captured position serializes its exact ratios dict, not the sentinel id")

        m.placements = [incomplete]
        XCTAssertNil(m.buildSpec(), "a layout with no complete placement is too incomplete")
    }

    func testLeavesTransitionAndEmptyNotifyBody() {
        var m = model("notify")
        m.triggerType = "state:frontmostApp"; m.transition = "leaves"; m.stateValue = "Safari"
        m.notifyTitle = "Hi"; m.notifyText = "   "   // whitespace-only body
        let spec = m.buildSpec()
        XCTAssertEqual(on(spec)?["leaves"] as? String, "Safari")
        XCTAssertNil(on(spec)?["becomes"], "a 'leaves' rule carries no 'becomes' key")
        XCTAssertNil(effect(spec)?["text"], "an empty notify body omits the text key")
    }
}
