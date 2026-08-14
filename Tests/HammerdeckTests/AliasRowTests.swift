import XCTest
@testable import HammerdeckKit

// Pure unit tests for the `aliasList` (App Launcher aliases) decoder/encoder.
// Same reason SiteRowTests exists: the Lua side is exercised by test/run.lua, but
// AliasRow.decode drives what the user SEES in the editor -- and the editor
// re-encodes on the next edit, so a decode that drops records rewrites stored
// config with the loss baked in. No bridge needed; AliasRow is plain Swift.
final class AliasRowTests: XCTestCase {

    private func rows(_ json: String) -> [AliasRow] { AliasRow.decode(json) }

    func testDecodesRecords() {
        let r = rows("""
        [{"bundleId":"com.microsoft.VSCode","aliases":["vsc","code"]},
         {"bundleId":"com.apple.Safari","aliases":["web"]}]
        """)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].bundleId, "com.microsoft.VSCode")
        XCTAssertEqual(r[0].aliases, ["vsc", "code"])
        XCTAssertEqual(r[1].aliases, ["web"])
    }

    // The whole point of the LenientRow wrapper: one wrong-typed record must cost
    // that record only. A whole-array `try?` would show "No aliases yet" for a
    // 20-alias config, and the next edit would persist that emptiness over all of it.
    func testOneBadRecordDoesNotWipeTheRest() {
        let r = rows("""
        [{"bundleId":"com.apple.Safari","aliases":"web"},
         {"bundleId":"com.apple.Terminal","aliases":["term"]},
         "not even an object",
         {"bundleId":"com.apple.dt.Xcode","aliases":["xc"]}]
        """)
        XCTAssertEqual(r.map(\.bundleId), ["com.apple.Terminal", "com.apple.dt.Xcode"],
                       "a wrong-typed field and a scalar element are skipped individually")
    }

    // A missing key falls back to the property default rather than dropping the
    // record -- a half-written row (app picked, no aliases yet) must survive.
    func testMissingKeysFallBackPerField() {
        let r = rows(#"[{"bundleId":"com.apple.Safari"}]"#)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].aliases, [])
    }

    // Decode preserves what is stored, duplicates included: the tag list renders by
    // INDEX, so equal aliases are two rows that delete independently. Dropping them
    // here would silently edit a value the user can still see in the launcher.
    func testDuplicateAliasesSurviveDecode() {
        let r = rows(#"[{"bundleId":"com.apple.Safari","aliases":["web","web","w"]}]"#)
        XCTAssertEqual(r.first?.aliases, ["web", "web", "w"])
    }

    func testNonArrayValuesDecodeToEmpty() {
        XCTAssertTrue(rows("").isEmpty)
        XCTAssertTrue(rows("not json at all").isEmpty)
        XCTAssertTrue(rows(#"{"bundleId":"x"}"#).isEmpty, "a bare object is not the array shape")
    }

    // `id` is view identity only. If it ever leaked into CodingKeys, merely opening
    // Settings would rewrite every record with a freshly minted one.
    func testEncodeOmitsTheViewIdentity() {
        var row = AliasRow()
        row.bundleId = "com.apple.Safari"
        row.aliases = ["web"]
        let encoded = AliasRow.encode([row])
        XCTAssertFalse(encoded.contains("\"id\""), "id must not be persisted: \(encoded)")
        XCTAssertEqual(rows(encoded).first?.aliases, ["web"], "round-trips without it")
    }

    // An alias may contain a space or a comma: nothing splits the text, so what the
    // user typed is one tag. Guards against a separator-splitting regression.
    func testAliasWithSeparatorCharactersSurvivesRoundTrip() {
        var row = AliasRow()
        row.bundleId = "com.apple.Safari"
        row.aliases = ["vs code", "a,b"]
        XCTAssertEqual(rows(AliasRow.encode([row])).first?.aliases, ["vs code", "a,b"])
    }
}
