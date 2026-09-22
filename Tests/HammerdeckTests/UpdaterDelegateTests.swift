import XCTest
import Sparkle
@testable import HammerdeckKit

// The updater delegate's wiring -- the beta channel and the cycle-outcome log --
// which cannot fail loudly on its own.
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
final class UpdaterDelegateTests: XCTestCase {

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

    // `SPUUpdaterDelegate` is declared `NS_SWIFT_UI_ACTOR`, so `UpdaterDelegate`
    // and its static are main-actor isolated: each test below needs `@MainActor`
    // to construct or read them. Not on the CLASS, because `setUp`/`tearDown`
    // override nonisolated members and only touch UserDefaults.
    //
    // And every read is hoisted into a `let` first. An `XCTAssert*` argument is
    // a `@autoclosure`, which stays NONISOLATED however the enclosing test is
    // annotated -- so `XCTAssertEqual(UpdaterDelegate.allowed, [])` does not
    // compile no matter how much isolation is added around it.

    // The selector Sparkle actually sends. Spelled out here as a literal, not
    // derived from the Swift name, so that renaming the Swift method cannot move
    // the expectation along with the code it is meant to pin.
    @MainActor
    func testTheDelegateRespondsToTheSelectorSparkleSends() {
        let responds = UpdaterDelegate().responds(to: Selector(("allowedChannelsForUpdater:")))
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
        let allowed = UpdaterDelegate.allowed
        XCTAssertEqual(allowed, [])
    }

    @MainActor
    func testSubscribedAllowsExactlyBeta() {
        UserDefaults.standard.set(true, forKey: Updater.betaChannelKey)
        let allowed = UpdaterDelegate.allowed
        XCTAssertEqual(allowed, ["beta"])
    }

    // An absent key is the state every existing install upgrades into, and it
    // must mean production -- not "no channel configured, offer everything".
    @MainActor
    func testAnUnsetKeyMeansProductionOnly() {
        UserDefaults.standard.removeObject(forKey: Updater.betaChannelKey)
        let allowed = UpdaterDelegate.allowed
        XCTAssertEqual(allowed, [])
    }

    // The cycle-outcome log has the same failure shape as the channel question:
    // an unmatched selector compiles and is never called, and the daily log then
    // looks exactly like a machine whose update checks all succeed quietly.
    @MainActor
    func testTheDelegateRespondsToTheCycleFinishedSelector() {
        let responds = UpdaterDelegate().responds(
            to: Selector(("updater:didFinishUpdateCycleForUpdateCheck:error:")))
        XCTAssertTrue(responds,
                      "Sparkle reports each cycle's outcome via "
                      + "updater:didFinishUpdateCycleForUpdateCheck:error:; unmatched, "
                      + "a failed background check leaves nothing in the daily log")
    }

    @MainActor
    func testTheDelegateRespondsToTheFoundUpdateSelector() {
        let responds = UpdaterDelegate().responds(to: Selector(("updater:didFindValidUpdate:")))
        XCTAssertTrue(responds, "without updater:didFindValidUpdate: the log cannot tell a "
                      + "found-and-dismissed update from a check that found nothing")
    }

    // "Up to date" arrives as an ERROR (SUNoUpdateError), so a classifier that
    // treated every non-nil error as a failure would log FAILED once a day on
    // every healthy machine -- and a real failure would then read as routine.
    func testOnLatestVersionIsLoggedAsUpToDate() {
        let line = UpdaterDelegate.cycleLogLine(check: .updatesInBackground,
                                                error: noUpdate(.onLatestVersion))
        XCTAssertEqual(line, "update check (background): up to date")
    }

    // The same error code also means "a newer build exists but excludes this Mac",
    // which is the answer to "why did I never get the update" and must not read
    // as up to date.
    func testAnUpdateThisMacCannotTakeIsNotLoggedAsUpToDate() {
        let line = UpdaterDelegate.cycleLogLine(check: .updatesInBackground,
                                                error: noUpdate(.systemIsTooOld))
        XCTAssertEqual(line, "update check (background): newer build exists but this macOS is too old for it")
    }

    // A 404 feed, in the shape Sparkle 2.10 builds it: SUAppcastDriver wraps the
    // downloader's error, and only the inner one carries the status code. The
    // outer sentence is generic, so without the cause the line cannot tell a 404
    // from a dead network.
    func testAFeed404IsLoggedWithItsStatus() {
        let download = Int(SUError.downloadError.rawValue)
        let cause = NSError(domain: SUSparkleErrorDomain, code: download, userInfo: [
            NSLocalizedDescriptionKey:
                "A network error occurred while downloading https://example.test/appcast.xml. not found (404)"])
        let failure = NSError(domain: SUSparkleErrorDomain, code: download, userInfo: [
            NSLocalizedDescriptionKey: "An error occurred in retrieving update information. Please try again later.",
            NSUnderlyingErrorKey: cause])
        let line = UpdaterDelegate.cycleLogLine(check: .updatesInBackground, error: failure)
        XCTAssertTrue(line.hasPrefix("update check (background) FAILED: SUSparkleErrorDomain 2001:"), line)
        XCTAssertTrue(line.hasSuffix("not found (404)"), line)
    }

    private func noUpdate(_ reason: SPUNoUpdateFoundReason) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
    }
}
