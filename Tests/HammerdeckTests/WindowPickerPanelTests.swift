import XCTest
@testable import HammerdeckKit

// The Window Deck picker's app grouping. The Lua suite's fake picker has no rows
// or headers, so this is the only coverage of how entries map onto table rows and
// what a group's Deck button returns. The panel is built but never shown: nothing
// flashes on screen, so no requireUITests() gate.
@MainActor
final class WindowPickerPanelTests: XCTestCase {

    private func entry(_ text: String, _ group: String?, checked: Bool = true) -> WindowPickerEntry {
        WindowPickerEntry(text: text, subText: group, iconToken: nil, color: "",
                          group: group, checked: checked)
    }

    private func panel(_ entries: [WindowPickerEntry],
                       onDone: @escaping ([Int]?) -> Void = { _ in }) -> WindowPickerPanel {
        WindowPickerPanel(title: "t", entries: entries, minPick: 2, palette: [],
                          heroLabel: "", heroOn: true) { picked, _, _ in onDone(picked) }
    }

    // MRU order in, grouped out: a group sits where its first member was, a key
    // with one entry and a keyless entry stay plain rows.
    private let mixed: [(String, String?)] = [
        ("code a", "code"), ("slack", "slack"), ("code b", "code"),
        ("chrome c", "chrome"), ("chrome d", "chrome"), ("bare", nil),
    ]

    func testGroupsByKeyInFirstAppearanceOrder() {
        let p = panel(mixed.map { entry($0.0, $0.1) })
        XCTAssertEqual(p.rowKinds, ["h:code", "e:1", "e:3", "e:2", "h:chrome", "e:4", "e:5", "e:6"])
    }

    func testEntriesStartInTheirGivenState() {
        let p = panel(mixed.map { entry($0.0, $0.1, checked: false) })
        XCTAssertEqual(p.checkedIndices, [])
    }

    func testGroupCheckboxUnchecksAFullGroupAndFillsAPartialOne() {
        let p = panel(mixed.map { entry($0.0, $0.1) })
        p.debugToggleGroup(1)
        XCTAssertEqual(p.checkedIndices, [2, 4, 5, 6], "a fully checked group unchecks")
        p.debugToggle(1)
        p.debugToggleGroup(1)
        XCTAssertEqual(p.checkedIndices, [1, 2, 3, 4, 5, 6], "a partly checked group checks all")
    }

    // The row-level drivers below run the key and click handlers against TABLE
    // rows. `mixed` lays out as: 0 h:code, 1 e:1, 2 e:3, 3 e:2 (slack),
    // 4 h:chrome, 5 e:4, 6 e:5, 7 e:6.

    func testFirstSelectionSkipsTheLeadingHeader() {
        let p = panel(mixed.map { entry($0.0, $0.1) })
        p.debugSelectFirstEntry()
        XCTAssertEqual(p.selectedTableRow, 1)
    }

    // Table row 3 holds entry 2. Toggling entry index 3 instead (table row used
    // as an entry index) would uncheck entry 4.
    func testSpaceTogglesTheEntryOnTheSelectedRow() {
        let p = panel(mixed.map { entry($0.0, $0.1) })
        p.debugSelectRow(3)
        p.debugSpace()
        XCTAssertEqual(p.checkedIndices, [1, 3, 4, 5, 6])
    }

    func testArrowsSkipHeadersAndWrap() {
        let p = panel(mixed.map { entry($0.0, $0.1) })
        p.debugSelectRow(3)
        p.debugMove(1)
        XCTAssertEqual(p.selectedTableRow, 5, "down past the chrome header")
        p.debugSelectRow(7)
        p.debugMove(1)
        XCTAssertEqual(p.selectedTableRow, 1, "wraps past the code header at the top")
    }

    func testHeaderClickTogglesItsGroupAndCmdReturnDecksIt() {
        var got: [Int]? = nil
        let p = panel(mixed.map { entry($0.0, $0.1) }) { got = $0 }
        p.debugSelectRow(5)
        p.debugClickRow(0)
        XCTAssertEqual(p.checkedIndices, [2, 4, 5, 6], "the code group unchecks")
        XCTAssertEqual(p.selectedTableRow, 1, "selection moves into the clicked group")
        p.debugReturn(command: true)
        XCTAssertEqual(got, [1, 3], "cmd+return decks the clicked group, not chrome")
    }

    func testGroupDeckReturnsTheWholeGroupWhateverIsChecked() {
        var got: [Int]? = nil
        let p = panel(mixed.map { entry($0.0, $0.1, checked: false) }) { got = $0 }
        p.debugToggle(1)
        p.debugGroupGo(2)
        XCTAssertEqual(got, [4, 5])
    }
}
