import XCTest
import Foundation
@testable import HammerdeckKit

// Pure unit tests for the localization plumbing: locale resolution + the Swift
// catalog reader. The i18n *logic* (lookup / fallback / plural) is exercised in
// Lua by test/run.lua; these guard the Swift-only pieces and the shipped catalog.
final class LocalizationTests: XCTestCase {

    // The shipped catalog is discovered as a selectable locale, alongside the
    // always-present "en" source -- so a zh-Hans speaker actually resolves to it.
    func testAvailableLocalesDiscoversShippedCatalog() {
        let codes = LocaleResolver.availableLocales()
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("zh-Hans"),
                      "ships app/i18n/zh-Hans.json -> zh-Hans must be selectable")
    }

    // The in-app override wins over the system languages; clearing it still
    // yields a non-empty resolved code.
    func testOverrideForcesLocale() {
        let key = LocaleResolver.overrideKey
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("zh-Hans", forKey: key)
        XCTAssertEqual(LocaleResolver.current, "zh-Hans")
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(LocaleResolver.current.isEmpty)
    }

    // A missing key always falls back to the inline English default -- the user
    // never sees a raw dotted key (true in every locale).
    func testStringsFallBackToDefault() {
        XCTAssertEqual(Strings.t("nonexistent.key.xyz", default: "Fallback"), "Fallback")
    }

    // The shipped zh-Hans catalog is valid JSON carrying the expected shared keys.
    func testShippedCatalogParses() {
        let path = resourceRoot() + "/app/i18n/zh-Hans.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            return XCTFail("missing \(path)")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(obj, "zh-Hans.json must be a JSON object")
        XCTAssertNotNil(obj?["window.noFocused"] as? String)
    }
}
