import XCTest
@testable import HammerdeckKit

// Pure unit tests for the `placementList` (Window Snap presets) decoder. Same
// reason SiteRowTests and AliasRowTests exist: the Lua side is covered by
// test/run.lua, but PlacementRow.decode drives what the editor SHOWS and the
// editor re-encodes on the next edit, so a decode that drops records rewrites
// stored config with the loss baked in. Here that also costs shortcuts: each
// preset becomes a bindable action keyed by its id.
final class PlacementRowTests: XCTestCase {

    // One wrong-typed field used to throw the whole array away, which would have
    // silently unbound every OTHER preset's shortcut on the next edit.
    func testOneBadRecordDoesNotWipeTheRest() {
        let rows = PlacementRow.decode("""
        [{"id":"left_third","name":"Left third","x":0,"y":0,"w":"wide","h":1},
         {"id":"top","name":"Top","x":0,"y":0,"w":1,"h":0.5},
         42,
         {"id":"right","name":"Right","x":0.5,"y":0,"w":0.5,"h":1}]
        """)
        XCTAssertEqual(rows.map(\.id), ["top", "right"],
                       "a wrong-typed field and a scalar element are skipped individually")
    }

    // A missing key falls back to the property default rather than dropping the
    // record; a missing id is regenerated, never empty (it names the snap's action).
    func testMissingKeysFallBackPerField() {
        let rows = PlacementRow.decode(#"[{"name":"Half"}]"#)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Half")
        XCTAssertEqual(rows[0].w, 1, accuracy: 0.0001)
        XCTAssertFalse(rows[0].id.isEmpty)
    }

    func testNonArrayValuesDecodeToEmpty() {
        XCTAssertTrue(PlacementRow.decode("").isEmpty)
        XCTAssertTrue(PlacementRow.decode("not json at all").isEmpty)
        XCTAssertTrue(PlacementRow.decode(#"{"id":"x"}"#).isEmpty, "a bare object is not the array shape")
    }

    // Unlike AliasRow, `id` IS persisted here -- it is the key the Lua side derives
    // the action id from, so a rename or reorder must not change it.
    func testEncodeKeepsTheId() {
        let row = PlacementRow(id: "left_third", name: "Left third", x: 0, y: 0, w: 0.33, h: 1)
        let encoded = PlacementRow.encode([row])
        XCTAssertTrue(encoded.contains("left_third"), encoded)
        XCTAssertEqual(PlacementRow.decode(encoded).first?.id, "left_third")
    }
}
