import XCTest
@testable import HammerdeckKit

// Pure unit tests for the `siteList` (Quick Sites) decoder/encoder. This is the
// one piece of the JSON-vs-legacy-text migration with no other coverage: the
// Lua side is exercised by test/run.lua, but the SwiftUI editor's SiteRow.decode
// drives what the user SEES (and re-encodes on edit), so a regression here
// silently corrupts stored config. No bridge needed -- SiteRow is plain Swift.
final class SiteRowTests: XCTestCase {

    // `incognito` defaults to false here on purpose: every existing assertion then
    // also pins "a site is not private unless it says so" -- the one default in this
    // struct where a wrong value would silently downgrade a privacy promise.
    private func assertRow(_ r: SiteRow, name: String, url: String,
                           browser: String = "", profile: String = "", app: Bool = false,
                           incognito: Bool = false,
                           _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.name, name, "name \(msg)", file: file, line: line)
        XCTAssertEqual(r.url, url, "url \(msg)", file: file, line: line)
        XCTAssertEqual(r.browser, browser, "browser \(msg)", file: file, line: line)
        XCTAssertEqual(r.profile, profile, "profile \(msg)", file: file, line: line)
        XCTAssertEqual(r.app, app, "app \(msg)", file: file, line: line)
        XCTAssertEqual(r.incognito, incognito, "incognito \(msg)", file: file, line: line)
    }

    // MARK: Legacy text (the pre-JSON `Name | URL | app` format)

    func testLegacyBareURL() {
        let rows = SiteRow.decode("github.com")
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "", url: "github.com")
    }

    func testLegacyNameAndURL() {
        let rows = SiteRow.decode("GitHub | github.com")
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "GitHub", url: "github.com")
    }

    func testLegacyAppFlag() {
        let rows = SiteRow.decode("Gmail | mail.google.com | app")
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "Gmail", url: "mail.google.com", app: true)
    }

    func testLegacyAppFlagWithoutName() {
        let rows = SiteRow.decode("example.com | app")
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "", url: "example.com", app: true)
    }

    func testLegacyMultilineSkipsBlankLines() {
        let rows = SiteRow.decode("a.com\n\n  B | b.com  \n")
        XCTAssertEqual(rows.count, 2)
        assertRow(rows[0], name: "", url: "a.com")
        assertRow(rows[1], name: "B", url: "b.com")
    }

    func testEmptyAndWhitespaceDecodeToNothing() {
        XCTAssertTrue(SiteRow.decode("").isEmpty)
        XCTAssertTrue(SiteRow.decode("\n   \n").isEmpty)
    }

    // MARK: JSON (the current storage format)

    func testJSONDecode() {
        let json = #"[{"name":"X","url":"x.com","browser":"com.apple.Safari","app":true}]"#
        let rows = SiteRow.decode(json)
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "X", url: "x.com", browser: "com.apple.Safari", profile: "", app: true)
    }

    func testJSONDecodePrivateFlag() {
        let json = #"[{"name":"P","url":"p.com","browser":"com.google.Chrome","incognito":true}]"#
        let rows = SiteRow.decode(json)
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "P", url: "p.com", browser: "com.google.Chrome",
                  profile: "", app: false, incognito: true)
        // And it survives the round trip, since the Lua side reads this key to
        // decide whether to pass --incognito.
        XCTAssertEqual(SiteRow.decode(SiteRow.encode(rows)).first?.incognito, true)
    }

    func testMalformedJSONDecodesToEmpty() {
        // A leading `[` routes to the JSON path; a parse failure must yield [],
        // NOT fall through to the legacy text parser (that would mangle it).
        XCTAssertTrue(SiteRow.decode("[ {bad").isEmpty)
    }

    // MARK: Encode + round-trip

    func testEncodeRoundTrip() {
        var a = SiteRow()
        a.name = "Example"; a.url = "example.com"; a.browser = "com.google.Chrome"
        a.profile = "Profile 2"; a.app = true
        var b = SiteRow(); b.url = "bing.com"

        let decoded = SiteRow.decode(SiteRow.encode([a, b]))
        XCTAssertEqual(decoded.count, 2)
        assertRow(decoded[0], name: "Example", url: "example.com",
                  browser: "com.google.Chrome", profile: "Profile 2", app: true)
        assertRow(decoded[1], name: "", url: "bing.com")
    }

    func testEncodeDoesNotEscapeSlashes() {
        var a = SiteRow(); a.url = "https://x.com/path"
        let s = SiteRow.encode([a])
        XCTAssertTrue(s.contains("https://x.com/path"), "got: \(s)")
        XCTAssertFalse(s.contains(#"\/"#), "slashes should not be escaped: \(s)")
    }

    // `id` IS persisted (it stopped being editor-only when each site became a
    // bindable action): the Lua side keys a site's action on it as "site_<id>", so
    // a shortcut bound to a site survives a rename, a URL edit, and a reorder.
    // Round-tripping it unchanged is exactly that promise.
    func testEncodePersistsIdUnchanged() {
        var a = SiteRow(); a.name = "Example"; a.url = "example.com"
        let s = SiteRow.encode([a])
        XCTAssertTrue(s.contains("\"id\""), "id must reach the JSON: \(s)")
        let decoded = SiteRow.decode(s)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, a.id, "the id must round-trip unchanged")
    }

    func testIdlessRecordGetsAFreshId() {
        // A config written before ids: decode must mint one (the Lua side falls
        // back to a URL slug until the next save persists it) rather than throw or
        // drop the record.
        let rows = SiteRow.decode(#"[{"name":"X","url":"x.com"}]"#)
        XCTAssertEqual(rows.count, 1)
        assertRow(rows[0], name: "X", url: "x.com")
        XCTAssertTrue(SiteRow.encode(rows).contains("\"id\""),
                      "the next save persists the minted id")
    }
}
