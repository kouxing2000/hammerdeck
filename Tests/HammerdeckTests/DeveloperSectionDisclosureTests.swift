import XCTest
@testable import HammerdeckKit

// The show-rule for General's two collapsed developer sections.
//
// Why this is worth a test at all. Collapsing them is a pure win ONLY if search
// still reaches them: SettingsView's search matches "Extensions" and "Agent
// Access (MCP)" by name, but that match decides just one thing -- whether the
// General row appears in the sidebar. It never filters or scrolls the pane. So
// a matched-but-collapsed section leaves the user on a page with no trace of
// what they searched for, which is worse than not collapsing at all.
//
// The result is DERIVED per render, never latched. A latch that only ever set
// true shipped in review and is what these tests exist to keep out: every title
// here contains a common letter, so typing the first character of an unrelated
// query opened a section and nothing ever closed it again.
@MainActor
final class DeveloperSectionDisclosureTests: XCTestCase {

    private func open(_ query: String = "", ext: Bool = false, mcp: Bool = false)
        -> (extensions: Bool, mcp: Bool) {
        DeveloperSectionDisclosure.shouldOpen(query: query,
                                              extensionsDirSet: ext, mcpEnabled: mcp)
    }

    func testBothStayClosedForAnUnconfiguredUser() {
        let r = open()
        XCTAssertFalse(r.extensions)
        XCTAssertFalse(r.mcp)
        // The whole point: a config-and-select user never sees either.
    }

    func testAConfiguredSectionOpensItself() {
        XCTAssertTrue(open(ext: true).extensions, "an extensions folder is set -- show it")
        XCTAssertFalse(open(ext: true).mcp, "and only that one")
        XCTAssertTrue(open(mcp: true).mcp, "the server is running -- show its port and status")
        XCTAssertFalse(open(mcp: true).extensions)
    }

    func testSearchOpensTheSectionItMatched() {
        XCTAssertTrue(open("mcp").mcp, "searching MCP must not land on a pane that hides it")
        XCTAssertTrue(open("agent").mcp)
        XCTAssertTrue(open("extens").extensions)
        XCTAssertFalse(open("extens").mcp, "an unmatched section stays closed")
    }

    func testSearchMatchingIsCaseInsensitive() {
        XCTAssertTrue(open("EXTENSIONS").extensions)
        XCTAssertTrue(open("agent access").mcp)
    }

    func testTheRawQueryIsTrimmed() {
        // The pane hands over the search field verbatim, so trimming is this
        // function's job -- an untrimmed "  Agent Access  " matches no title.
        XCTAssertTrue(open("  Agent Access  ").mcp)
        XCTAssertTrue(open("\n Extensions ").extensions)
    }

    // THE regression this file exists for. Every title contains a common letter,
    // so the app -- which feeds one prefix per keystroke -- walks through states
    // a test asserting only the finished query never visits.
    func testNoSingleCharacterQueryOpensAnything() {
        for ch in "abcdefghijklmnopqrstuvwxyz" {
            let r = open(String(ch))
            XCTAssertFalse(r.extensions, "'\(ch)' alone opened Extensions")
            XCTAssertFalse(r.mcp, "'\(ch)' alone opened Agent Access")
        }
    }

    func testEveryPrefixOfAnUnrelatedQueryStaysClosed() {
        // Typing "appearance" must not flash either section open on the way.
        let word = "appearance"
        for n in 1...word.count {
            let prefix = String(word.prefix(n))
            let r = open(prefix)
            XCTAssertFalse(r.extensions, "prefix '\(prefix)' opened Extensions")
            XCTAssertFalse(r.mcp, "prefix '\(prefix)' opened Agent Access")
        }
    }

    func testClearingTheQueryClosesWhatSearchOpened() {
        // Derived, not latched: the same inputs minus the query must close it.
        XCTAssertTrue(open("mcp").mcp)
        XCTAssertFalse(open("").mcp, "an empty query must not keep it open")
    }

    func testAQueryMatchingNeitherOpensNeither() {
        let r = open("language")
        XCTAssertFalse(r.extensions)
        XCTAssertFalse(r.mcp)
    }

    func testWhitespaceOnlyQueryIsNotTreatedAsAMatch() {
        // The contract: a search field holding only spaces is not a search.
        let r = open("   ")
        XCTAssertFalse(r.extensions, "a blank query is not a match")
        XCTAssertFalse(r.mcp)
    }
}
