import XCTest
import Sparkle
@testable import HammerdeckKit

// The beta channel's wiring, which cannot fail loudly on its own.
//
// Every `SPUUpdaterDelegate` method is OPTIONAL. A delegate whose method does not
// map onto the selector Sparkle looks for still compiles, still satisfies the
// protocol, and is simply never called -- so the beta toggle would flip, persist,
// and change nothing, with no error in any log. The same silent shape appears if
// the delegate is not retained (`SPUStandardUpdaterController` holds it `__weak`).
//
// These assertions sit on the wiring rather than on the method body for that
// reason: calling `allowedChannels(for:)` directly would pass in every broken
// arrangement above.
final class UpdaterChannelTests: XCTestCase {

    private var previous: Any?

    override func setUp() {
        super.setUp()
        previous = UserDefaults.standard.object(forKey: Updater.betaChannelKey)
    }

    override func tearDown() {
        // Restore rather than remove. The test bundle's defaults domain is
        // xctest's, not the app's, so this cannot reach a real subscription --
        // but the tests share that domain with each other, and leaving the key
        // set would make a later one depend on execution order.
        if let previous {
            UserDefaults.standard.set(previous, forKey: Updater.betaChannelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Updater.betaChannelKey)
        }
        super.tearDown()
    }

    // `SPUUpdaterDelegate` is declared `NS_SWIFT_UI_ACTOR`, so `ChannelDelegate`
    // and its static are main-actor isolated: each test below needs `@MainActor`
    // to construct or read them. Not on the CLASS, because `setUp`/`tearDown`
    // override nonisolated members and only touch UserDefaults.
    //
    // And every read is hoisted into a `let` first. An `XCTAssert*` argument is
    // a `@autoclosure`, which stays NONISOLATED however the enclosing test is
    // annotated -- so `XCTAssertEqual(ChannelDelegate.allowed, [])` does not
    // compile no matter how much isolation is added around it.

    // The selector Sparkle actually sends. Spelled out here as a literal, not
    // derived from the Swift name, so that renaming the Swift method cannot move
    // the expectation along with the code it is meant to pin.
    @MainActor
    func testTheDelegateRespondsToTheSelectorSparkleSends() {
        let responds = ChannelDelegate().responds(to: Selector(("allowedChannelsForUpdater:")))
        XCTAssertTrue(responds,
                      "Sparkle asks for channels via allowedChannelsForUpdater:; an unmatched "
                      + "selector leaves the beta toggle inert and reports nothing")
    }

    // Off is an EMPTY set, never a set naming the default channel: Sparkle
    // documents the default as always included, so returning something like
    // ["release"] would filter out the real releases instead of adding to them.
    @MainActor
    func testUnsubscribedAllowsNoExtraChannel() {
        UserDefaults.standard.set(false, forKey: Updater.betaChannelKey)
        let allowed = ChannelDelegate.allowed
        XCTAssertEqual(allowed, [])
    }

    @MainActor
    func testSubscribedAllowsExactlyBeta() {
        UserDefaults.standard.set(true, forKey: Updater.betaChannelKey)
        let allowed = ChannelDelegate.allowed
        XCTAssertEqual(allowed, ["beta"])
    }

    // An absent key is the state every existing install upgrades into, and it
    // must mean production -- not "no channel configured, offer everything".
    @MainActor
    func testAnUnsetKeyMeansProductionOnly() {
        UserDefaults.standard.removeObject(forKey: Updater.betaChannelKey)
        let allowed = ChannelDelegate.allowed
        XCTAssertEqual(allowed, [])
    }
}
