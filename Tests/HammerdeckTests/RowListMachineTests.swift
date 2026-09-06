// RowListMachineTests -- the seed/persist transitions behind every row editor.
//
// `RowListPersistence.swift`'s own header names two bugs it was written to
// prevent: "decoding counted as an edit and rewrote stored config on open", and
// "an externally emptied value round-tripped `[]` back into defaults". Both are
// state transitions, and both shipped. Until the machine was lifted out of the
// ViewModifier neither could be asserted without rendering a view, so the file
// that carried the bug history was the one file with no test.
//
// Each test below names the bug it fences, not the method it calls.

import XCTest
@testable import HammerdeckKit

private typealias Machine = RowListMachine<String>

final class RowListMachineTests: XCTestCase {

    /// The modifier's `apply`, so a test drives the same loop the view does:
    /// a `.setRows` effect changes the rows, which feeds `rowsChanged` back in.
    /// Returns every write the machine asked for.
    private func run(_ m: inout Machine, _ effect: Machine.Effect,
                     rows: inout [String]) -> [[String]] {
        switch effect {
        case .none:
            return []
        case .setRows(let new):
            rows = new
            return run(&m, m.rowsChanged(to: new), rows: &rows)
        case .persist(let new):
            rows = new
            return [new]
        }
    }

    // MARK: - Bug 1: opening the page must not rewrite stored config

    func testSeedingIsNotAnEdit() {
        var m = Machine()
        var rows: [String] = []
        let writes = run(&m, m.appeared(json: "a,b", decode: { $0.components(separatedBy: ",") }),
                         rows: &rows)
        XCTAssertEqual(rows, ["a", "b"], "the seed reaches the binding")
        XCTAssertEqual(writes, [], "...and writes NOTHING: opening a page is not an edit")
    }

    func testASeedThatReEncodesDifferentlyIsStillNotAnEdit() {
        // The reason `persisted` holds ROWS and not the raw text. A decode
        // legitimately produces something that re-encodes to a different string
        // -- SiteRow mints a missing id, a hand-edited blob differs in key order.
        // Comparing text would call that an edit and overwrite the user's config
        // on open, which is the shipped bug in its exact original form.
        var m = Machine()
        var rows: [String] = []
        let writes = run(&m, m.appeared(json: "  A , B  ", decode: { raw in
            raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }), rows: &rows)
        XCTAssertEqual(rows, ["A", "B"])
        XCTAssertEqual(writes, [], "normalization during decode is not a user edit")
    }

    func testAppearingTwiceDoesNotReSeedOverAPendingEdit() {
        // A re-render re-fires onAppear. Re-decoding there would throw away an
        // edit the user has made but the option has not echoed back yet.
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "a", decode: { [$0] }), rows: &rows)
        let edits = run(&m, m.rowsChanged(to: ["a", "b"]), rows: &rows)
        XCTAssertEqual(edits, [["a", "b"]], "a real edit writes")

        let second = run(&m, m.appeared(json: "a", decode: { [$0] }), rows: &rows)
        XCTAssertEqual(second, [], "the second appear decides nothing")
        XCTAssertEqual(rows, ["a", "b"], "and leaves the edit standing")
    }

    // MARK: - Bug 2: an external clear must not echo "[]" back

    func testAnExternalClearEmptiesTheListWithoutWritingItBack() {
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "a,b", decode: { $0.components(separatedBy: ",") }),
                rows: &rows)

        // The option was reset elsewhere -- the key is GONE. Writing "[]" here
        // recreates it, which is how a reset silently stopped resetting.
        let writes = run(&m, m.jsonChanged(to: "", rows: rows), rows: &rows)
        XCTAssertEqual(rows, [], "the list empties")
        XCTAssertEqual(writes, [], "...and nothing is written back into the cleared key")
    }

    func testANonEmptyExternalChangeDoesNotDisturbTheRows() {
        // Only the EMPTY case acts. An external value that is merely different
        // must not clobber what the user has on screen.
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "a", decode: { [$0] }), rows: &rows)
        let writes = run(&m, m.jsonChanged(to: "c,d", rows: rows), rows: &rows)
        XCTAssertEqual(rows, ["a"], "rows are untouched")
        XCTAssertEqual(writes, [])
    }

    func testClearingAnAlreadyEmptyListIsANoOp() {
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "", decode: { _ in [] }), rows: &rows)
        let writes = run(&m, m.jsonChanged(to: "", rows: rows), rows: &rows)
        XCTAssertEqual(writes, [], "no rows to clear, so no effect and no write")
    }

    // MARK: - A real edit must still get through

    func testARealEditWritesExactlyOnce() {
        // The guard that stops the two bugs above is the same one that could
        // swallow every genuine edit -- without this, a machine that returned
        // `.none` unconditionally would pass every test in this file.
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "a", decode: { [$0] }), rows: &rows)

        XCTAssertEqual(run(&m, m.rowsChanged(to: ["a", "b"]), rows: &rows), [["a", "b"]])
        XCTAssertEqual(run(&m, m.rowsChanged(to: ["a", "b"]), rows: &rows), [],
                       "re-reporting the same rows is not a second edit")
        XCTAssertEqual(run(&m, m.rowsChanged(to: ["a"]), rows: &rows), [["a"]],
                       "and editing back to an earlier value IS an edit")
    }

    func testAnEditAfterAnExternalClearWrites() {
        // The clear sets `persisted` to []. If it had set it to anything else,
        // the user's first row after a reset would be swallowed as an echo.
        var m = Machine()
        var rows: [String] = []
        _ = run(&m, m.appeared(json: "a", decode: { [$0] }), rows: &rows)
        _ = run(&m, m.jsonChanged(to: "", rows: rows), rows: &rows)
        XCTAssertEqual(run(&m, m.rowsChanged(to: ["fresh"]), rows: &rows), [["fresh"]])
    }
}
