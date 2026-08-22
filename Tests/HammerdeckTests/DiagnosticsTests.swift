import XCTest
import AppKit
@testable import HammerdeckKit

// The diagnostics report copies a load failure's raw Lua error text verbatim,
// which is where absolute paths actually reach a document written to be pasted
// into a public issue. The report's own header promises "no file paths outside
// the app's own" and its log line already tilde-abbreviates for exactly this
// reason -- the passthrough is the one place that promise leaked.
@MainActor
final class DiagnosticsRedactionTests: XCTestCase {

    func testHomeDirectoryIsAbbreviated() {
        let home = NSHomeDirectory()
        let raw = "\(home)/workspaces/git/hammerdeck/app/loader.lua:67: '}' expected"
        let out = Diagnostics.redactPaths(raw)
        XCTAssertFalse(out.contains(home), "the account short name must not survive")
        XCTAssertTrue(out.hasPrefix("~/workspaces"), "got: \(out)")
    }

    func testTextWithoutPathsIsUnchanged() {
        let raw = "duplicate feature id: app_launcher"
        XCTAssertEqual(Diagnostics.redactPaths(raw), raw)
    }
}
