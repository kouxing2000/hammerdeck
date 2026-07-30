import XCTest
@testable import HammerdeckKit

// The private-window promise, pinned. Quick Sites can mark a site "open in a
// private window", and the whole value of that checkbox is that a window it
// produces is NEVER recorded. What carries the promise is the ALLOWLIST of
// browsers verified to honor `--incognito` (plus the seam's refusal of everything
// else) and the switch vector itself -- both of which used to sit inline in
// `openSite`'s bridge function where no test could reach them, so a green Lua
// suite (which only sees the fake adapter) was not evidence for any of this.
//
// The failure these guard against is specific: a window the UI calls private that
// actually persists the visit. It is silent -- the browser launches fine, the
// feature logs "opened private", and the user finds out never.
final class BrowserPrivateWindowTests: XCTestCase {

    // MARK: which browsers may be promised a private window

    func testOnlyVerifiedBrowsersMayGoPrivate() {
        XCTAssertTrue(BrowserCatalog.supportsPrivateWindow("com.google.Chrome"))
        XCTAssertTrue(BrowserCatalog.supportsPrivateWindow("org.chromium.Chromium"))
    }

    /// The regression this exists for: `supportsPrivateWindow` once WAS
    /// `isChromium`, i.e. a set built to answer "takes --app= and
    /// --profile-directory=". These are Chromium and take those switches, but
    /// nobody has verified they honor `--incognito` -- Edge documents
    /// `--inprivate`, Arc ignores most Chromium switches -- and an unhonored
    /// switch opens a NORMAL window that the app would call private. Until each is
    /// checked by hand, the honest answer is to refuse.
    func testUnverifiedChromiumForksAreRefusedNotAssumed() {
        for id in ["com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi"] {
            XCTAssertTrue(BrowserCatalog.isChromium(id), "\(id) should still be Chromium")
            XCTAssertFalse(BrowserCatalog.supportsPrivateWindow(id),
                           "\(id) is not verified for --incognito, so it must not be promised")
        }
    }

    func testNonChromiumAndUnknownCannotGoPrivate() {
        // Safari exposes no private-browsing switch to a launch at all; Firefox's
        // would need a launch path open_site does not have.
        XCTAssertFalse(BrowserCatalog.supportsPrivateWindow("com.apple.Safari"))
        XCTAssertFalse(BrowserCatalog.supportsPrivateWindow("org.mozilla.firefox"))
        // "System default" is deliberately NOT resolved here -- unknown, and the
        // seam is only ever handed an already-resolved id.
        XCTAssertFalse(BrowserCatalog.supportsPrivateWindow(""))
    }

    // MARK: the launch switches

    func testPrivateAddsIncognitoSwitch() {
        let args = Native.chromiumArgs(profile: "", app: false, incognito: true,
                                       url: "https://example.com")
        XCTAssertTrue(args.contains("--incognito"), "got: \(args)")
        XCTAssertEqual(args.last, "https://example.com")
    }

    func testNonPrivateNeverAddsIncognitoSwitch() {
        let args = Native.chromiumArgs(profile: "", app: false, incognito: false,
                                       url: "https://example.com")
        XCTAssertFalse(args.contains("--incognito"), "got: \(args)")
    }

    /// Private and app mode COMPOSE: Chrome opens a window that is chromeless AND
    /// private. This was briefly forced apart on the assumption it would not work;
    /// a probe (2026-07-30) showed otherwise -- the window was confirmed private by
    /// eye and by its absence from browser_list_tabs. Keep both switches.
    func testPrivateAndAppWindowCompose() {
        let args = Native.chromiumArgs(profile: "", app: true, incognito: true,
                                       url: "https://example.com")
        // Whole-vector equality, not `contains`: the seam's note says the ORDER is
        // the one the probe exercised and tells the next person to re-probe rather
        // than reason about it. A `contains` pair would stay green while a refactor
        // emitted `--app=` first -- the one variant nobody has watched Chrome
        // resolve -- so the assertion has to see the dimension the comment claims
        // matters.
        XCTAssertEqual(args, ["--incognito", "--app=https://example.com"])
    }

    /// In app mode the URL rides INSIDE the `=`-bound `--app=` token, so it is a
    /// single argv element and needs no `--` terminator to stay un-parseable as a
    /// switch. Worth pinning now that the private path can take this branch too.
    func testAppModeKeepsTheURLInsideItsOwnToken() {
        let args = Native.chromiumArgs(profile: "", app: true, incognito: true,
                                       url: "--disable-web-security")
        XCTAssertEqual(args, ["--incognito", "--app=--disable-web-security"])
    }

    func testAppWindowSurvivesWhenNotPrivate() {
        let args = Native.chromiumArgs(profile: "", app: true, incognito: false,
                                       url: "https://example.com")
        XCTAssertTrue(args.contains("--app=https://example.com"), "got: \(args)")
    }

    /// Each Chrome profile has its own private session, so the two compose.
    func testProfileIsKeptForAPrivateWindow() {
        let args = Native.chromiumArgs(profile: "Profile 2", app: false, incognito: true,
                                       url: "https://example.com")
        XCTAssertEqual(args.first, "--profile-directory=Profile 2", "got: \(args)")
        XCTAssertTrue(args.contains("--incognito"), "got: \(args)")
    }

    /// `--` ends switch parsing, so a URL starting with `-` can never be read as a
    /// Chrome flag. Checked here too because the private path takes this branch.
    func testURLIsAlwaysSwitchTerminatedInTabMode() {
        let args = Native.chromiumArgs(profile: "", app: false, incognito: true,
                                       url: "--disable-web-security")
        XCTAssertEqual(args.suffix(2).first, "--")
        XCTAssertEqual(args.last, "--disable-web-security")
    }
}
