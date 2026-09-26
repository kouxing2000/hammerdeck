import AppKit
import XCTest
@testable import HammerdeckKit

// An info row (valid = false) never reaches onSelect. Click and arrow stepping
// each check the row they act on; Return, the quick keys and Lua's h.select all
// pick by row NUMBER through select(n), so select(n) refuses an info row itself.
// The panel is built but never shown: nothing flashes on screen, so no
// requireUITests() gate.
@MainActor
final class ChooserPanelTests: XCTestCase {

    /// Every onSelect delivery, in order (nil = dismissed).
    private var delivered: [Int?] = []

    private func entry(_ text: String, valid: Bool = true) -> ChooserEntry {
        ChooserEntry(text: text, subText: nil, iconToken: nil, valid: valid)
    }

    private func panel() -> ChooserPanel {
        ChooserPanel(searchSubText: false,
                     onSelect: { [unowned self] in self.delivered.append($0) },
                     onHide: {})
    }

    /// A picker re-opened on its lone "Scanning…" row after a real row was
    /// highlighted.
    private func loneInfoRowAfterAPick() -> ChooserPanel {
        let p = panel()
        p.setChoices([entry("alpha"), entry("beta")])
        p.setSelectedRow(1)
        XCTAssertEqual(p.selectedRow(), 1, "precondition: a real row is highlighted")
        p.setChoices([entry("Scanning…", valid: false)])
        return p
    }

    /// Return, through the method the search field's editor calls.
    private func pressReturn(_ p: ChooserPanel) {
        _ = p.control(NSTextField(), textView: NSTextView(),
                      doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    /// Whether reloadData keeps a selection is AppKit's behaviour, not ours (on
    /// macOS 27 it drops it), so the panel clears it itself when no row is valid.
    func testLoneInfoRowLeavesNothingSelected() {
        let p = loneInfoRowAfterAPick()
        XCTAssertEqual(p.selectedRow(), 0, "no visible row is valid, so nothing is selected")
        pressReturn(p)
        XCTAssertEqual(delivered, [], "Return with nothing selected picks nothing")
    }

    /// Lua's h.setSelectedRow can put the highlight on an info row; Return must
    /// still refuse it.
    func testReturnOnAnInfoRowDeliversNothing() {
        let p = loneInfoRowAfterAPick()
        p.setSelectedRow(1)
        XCTAssertEqual(p.selectedRow(), 1, "precondition: the info row is highlighted")
        pressReturn(p)
        XCTAssertEqual(delivered, [], "Return on an info row picks nothing")
    }

    func testSelectOnAnInfoRowDeliversNothing() {
        let p = loneInfoRowAfterAPick()
        p.select(1)
        XCTAssertEqual(delivered, [], "select(n) on an info row is a no-op")

        // An info row below real rows (a trailing "some folders failed" line).
        let q = panel()
        q.setChoices([entry("alpha"), entry("Some folders failed", valid: false)])
        q.select(2)
        XCTAssertEqual(delivered, [], "select(n) refuses an info row next to valid ones too")
    }

    /// A refused pick leaves the panel open: once real rows land, Return picks.
    func testRefusedPickLeavesThePanelLive() {
        let p = loneInfoRowAfterAPick()
        p.setSelectedRow(1)
        pressReturn(p)
        p.select(1)
        p.setChoices([entry("alpha"), entry("beta")])
        p.setSelectedRow(2)
        pressReturn(p)
        XCTAssertEqual(delivered, [2], "only the real row picked after the refusals is delivered")
    }

    /// Out of range still cancels: release-to-pick polls call select(0) when
    /// nothing is selected, and askChoice's dismiss rides select(0).
    func testOutOfRangeSelectStillCancels() {
        let p = loneInfoRowAfterAPick()
        p.select(0)
        XCTAssertEqual(delivered, [nil], "select(0) dismisses")
    }
}
