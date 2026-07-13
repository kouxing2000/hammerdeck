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

    // THE CHROME LOCALIZATION GATE -- the Swift half of test/cases/_integration/platform/
    // i18n_parity.lua (which guards the Lua/feature half).
    //
    // Strings.t falls back to its inline English default when a key is missing, so an
    // untranslated string is INVISIBLE at runtime: the Chinese UI just speaks English and
    // nothing fails. An audit in 2026-07 found 69 such keys -- the ENTIRE Rules automation
    // builder, most of the Usage Stats report -- with no test able to see them.
    //
    // So: scan the real Swift sources for every Strings.t / Strings.plural call the UI can
    // render, and assert the shipped zh-Hans catalog carries that key. Presence, not value:
    // a string that is correctly identical in Chinese (a brand name) still declares its key,
    // which keeps the intent explicit rather than heuristic.
    //
    // A key that is NOT a plain literal -- "recipe.\(id)", "rules.triggerField." + field --
    // cannot be resolved by reading source. Such a site is NOT skipped: its literal prefix
    // must name a DYNAMIC FAMILY declared below, each of which is checked against the list
    // the UI actually renders. An unrecognised family, or a call the scanner cannot parse at
    // all, FAILS -- a gate that quietly skips what it cannot read certifies nothing, which is
    // how `Strings.plural` (4 sites) and `rules.triggerField.*` sat unguarded behind a green
    // test until a review caught them.
    func testEveryChromeStringIsTranslated() throws {
        let root = repoRoot()
        let catalogPath = root + "/app/i18n/zh-Hans.json"
        guard let data = FileManager.default.contents(atPath: catalogPath),
              let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return XCTFail("missing or invalid \(catalogPath)")
        }

        // Dynamic families: literal prefix -> the real keys it can produce at runtime.
        // `rules.triggerField.` is keyed by a SIGNAL's `provides` value, which lives in Lua
        // (signals.lua) -- so it is guarded there, by i18n_parity.lua, against the real
        // signal list. Naming it here keeps the site from counting as unparsed.
        let dynamicFamilies: [String: [String]] = [
            "recipe.": PlacementListEditor.recipeStringKeys,
            "rules.triggerField.": [],   // covered by i18n_parity.lua (Lua owns the noun set)
        ]

        // Every localization call site, then the two shapes we can resolve.
        let anyCall = try NSRegularExpression(pattern: #"Strings\.(?:t|plural)\("#)
        let literal = try NSRegularExpression(pattern: #"Strings\.(?:t|plural)\(\s*"([^"\\]+)"\s*,"#)
        let dynamic = try NSRegularExpression(pattern: #"Strings\.(?:t|plural)\(\s*"([^"]*?)(?:\\\(|"\s*\+)"#)

        var missing: [String] = [], unparsed: [String] = []
        var scannedFiles = 0, scannedKeys = 0, dynamicSites = 0
        let enumerator = FileManager.default.enumerator(atPath: root + "/app")
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift"),
                  let raw = try? String(contentsOfFile: root + "/app/" + rel, encoding: .utf8)
            else { continue }
            // Comments are not call sites: this file's own header documents
            // `Strings.t("recipe.<id>")` in prose, and the scanner must not read that as an
            // unverifiable call. Blanked (not deleted) so offsets and line numbers survive.
            let src = codeOnly(raw)
            scannedFiles += 1
            let ns = src as NSString
            let all = NSRange(location: 0, length: ns.length)

            var resolved = Set<Int>()   // call-site offsets the scanner understood
            for m in literal.matches(in: src, range: all) {
                resolved.insert(m.range.location)
                let key = ns.substring(with: m.range(at: 1))
                scannedKeys += 1
                if catalog[key] == nil { missing.append("\(rel): \(key)") }
            }
            for m in dynamic.matches(in: src, range: all) {
                resolved.insert(m.range.location)
                dynamicSites += 1
                let prefix = ns.substring(with: m.range(at: 1))
                guard let keys = dynamicFamilies[prefix] else {
                    unparsed.append("\(rel): dynamic key \"\(prefix)…\" is not a declared family")
                    continue
                }
                for key in keys where catalog[key] == nil {
                    missing.append("\(rel) [\(prefix)…]: \(key)")
                }
            }
            // Anything the two shapes above did not claim is a call the gate cannot vouch for.
            for m in anyCall.matches(in: src, range: all) where !resolved.contains(m.range.location) {
                let line = ns.substring(with: ns.lineRange(for: m.range))
                unparsed.append("\(rel): unparsed call -- \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        // A zero-file / zero-key / zero-dynamic scan would pass vacuously -- an all-clear that
        // checked nothing. The host chrome has all three today.
        XCTAssertGreaterThan(scannedFiles, 0, "scanned no Swift sources under \(root)/app")
        XCTAssertGreaterThan(scannedKeys, 0, "found no Strings.t/plural calls to check")
        XCTAssertGreaterThan(dynamicSites, 0, "found no dynamic-key sites -- the scanner's "
                             + "dynamic branch is dead, so it can no longer catch a new one")
        XCTAssertTrue(unparsed.isEmpty,
                      "\(unparsed.count) localization call site(s) the gate cannot verify -- "
                      + "give the key a literal, or declare its dynamic family:\n  "
                      + unparsed.joined(separator: "\n  "))
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) chrome string(s) have no zh-Hans translation and will "
                      + "silently render English:\n  " + missing.joined(separator: "\n  "))
    }

    /// Blank out `//` and `/* */` comments, replacing them with spaces so every offset and
    /// line number still lines up with the original. String literals are respected: a `//`
    /// inside "https://..." must NOT start a comment, or real code after it on that line
    /// would vanish from the scan -- a silent hole in a gate whose whole job is to have none.
    private func codeOnly(_ src: String) -> String {
        var out = "", inString = false, inLine = false, inBlock = false, escaped = false
        var chars = Array(src), i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) } else { out.append(" ") }
            } else if inBlock {
                if c == "*" && next == "/" { inBlock = false; out += "  "; i += 2; continue }
                out.append(c == "\n" ? c : " ")
            } else if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "/" && next == "/" {
                inLine = true; out += "  "; i += 2; continue
            } else if c == "/" && next == "*" {
                inBlock = true; out += "  "; i += 2; continue
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// The REPO root, derived from this test file's own path -- not resourceRoot(), which
    /// points at a bundle's resources. Swift SOURCES are not resources: in a packaged app
    /// that tree holds no .swift at all, and the scan would find nothing to check.
    private func repoRoot(file: StaticString = #filePath) -> String {
        URL(fileURLWithPath: "\(file)")            // .../Tests/HammerdeckTests/LocalizationTests.swift
            .deletingLastPathComponent()           // .../Tests/HammerdeckTests
            .deletingLastPathComponent()           // .../Tests
            .deletingLastPathComponent()           // repo root
            .path
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
