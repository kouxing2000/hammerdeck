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
    @MainActor
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
            // The effect-verb pills read their key off the per-kind table
            // (RuleEffectKinds), so no literal spells them out any more. Declaring
            // the family keeps every verb checked for a translation -- moving keys
            // into a data table must not quietly exempt them from the gate.
            "rules.verb.": EffectKinds.verbStringKeys,
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

    // THE OTHER DIRECTION: a catalog key nothing asks for any more. The test above scans
    // call site -> catalog (a missing translation silently speaks English); nothing scanned
    // catalog -> call site, so a key outlived its call site invisibly. That is not
    // cosmetic: a dead key is a string a translator spends time on, and it makes the
    // catalog a poor answer to "what does this app actually say". Six such keys were
    // removed by hand in one 2026-07 session (a deleted Settings row and a deleted feature
    // action) -- by hand, because no gate could see them.
    //
    // The global catalog serves BOTH hosts, so both source trees are scanned: Swift's
    // `Strings.t/plural`, and Lua's `i18n.t/format/plural` (platform modules) plus `ctx.t /
    // ctx.plural` (a feature may reach a DOTTED global key -- see i18n.tFeature's fallback).
    // A key is also live when it matches a CONCATENATED prefix ("rules.signal." .. name) --
    // the same dynamic families the scan above resolves from the other side.
    @MainActor
    func testCatalogHasNoOrphanedKeys() throws {
        let root = repoRoot()
        guard let data = FileManager.default.contents(atPath: root + "/app/i18n/zh-Hans.json"),
              let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return XCTFail("missing or invalid zh-Hans.json")
        }
        let swiftLiteral = try NSRegularExpression(pattern: #"Strings\.(?:t|plural)\(\s*"([^"\\]+)"\s*,"#)
        let swiftPrefix  = try NSRegularExpression(pattern: #"Strings\.(?:t|plural)\(\s*"([^"]*?)(?:\\\(|"\s*\+)"#)
        // `tFeature`/`formatFeature` are deliberately ABSENT: they take the
        // feature id FIRST, so matching their leading literal would capture an
        // id as if it were a key (and miss the real one). Every call site passes
        // a variable id today, so they contribute no literals either way.
        // `formatPlural` IS key-first, so it belongs here.
        let luaLiteral   = try NSRegularExpression(
            pattern: #"(?:i18n\.(?:t|format|plural|formatPlural)|ctx\.(?:t|plural))\(\s*"([^"]+)""#)
        let luaPrefix    = try NSRegularExpression(
            pattern: #"(?:i18n\.(?:t|format|plural)|ctx\.(?:t|plural))\(\s*"([^"]*?)"\s*\.\."#)

        var referenced = Set<String>(), prefixes = Set<String>()
        var scannedSwift = 0, scannedLua = 0
        let enumerator = FileManager.default.enumerator(atPath: root + "/app")
        while let rel = enumerator?.nextObject() as? String {
            let isSwift = rel.hasSuffix(".swift"), isLua = rel.hasSuffix(".lua")
            guard isSwift || isLua,
                  let raw = try? String(contentsOfFile: root + "/app/" + rel, encoding: .utf8)
            else { continue }
            // Swift comments are blanked (this file documents key shapes in prose); Lua
            // comments are left as-is -- codeOnly understands `//`, not `--`, and a key
            // named only inside a Lua comment still counts as documented, not orphaned.
            let src = isSwift ? codeOnly(raw) : raw
            let ns = src as NSString
            let all = NSRange(location: 0, length: ns.length)
            if isSwift { scannedSwift += 1 } else { scannedLua += 1 }
            for m in (isSwift ? swiftLiteral : luaLiteral).matches(in: src, range: all) {
                referenced.insert(ns.substring(with: m.range(at: 1)))
            }
            for m in (isSwift ? swiftPrefix : luaPrefix).matches(in: src, range: all) {
                let p = ns.substring(with: m.range(at: 1))
                if !p.isEmpty { prefixes.insert(p) }
            }
        }

        let orphans = catalog.keys
            .filter { !referenced.contains($0) && !prefixes.contains(where: $0.hasPrefix) }
            .sorted()

        // A vacuous scan (no sources, no keys) would pass while checking nothing.
        XCTAssertGreaterThan(scannedSwift, 0, "scanned no Swift sources under \(root)/app")
        XCTAssertGreaterThan(scannedLua, 0, "scanned no Lua sources under \(root)/app")
        XCTAssertGreaterThan(referenced.count, 0, "resolved no localization keys at all")
        // The scan reads `ctx.t("x")` -- a FEATURE-relative key -- as a global
        // reference too. That can only mask a global orphan if some global key
        // is spelled exactly like a feature key, and i18n.tFeature falls back to
        // the global catalog ONLY for dotted keys. Welding that shut: every
        // global key is dotted, so no bare feature key can ever shadow one.
        XCTAssertTrue(catalog.keys.allSatisfy { $0.contains(".") },
                      "every global catalog key must be dotted -- an undotted key could be "
                      + "masked by a same-named feature-relative ctx.t call: "
                      + catalog.keys.filter { !$0.contains(".") }.sorted().joined(separator: ", "))
        XCTAssertTrue(orphans.isEmpty,
                      "\(orphans.count) zh-Hans key(s) no source asks for -- delete them, or "
                      + "restore the call site that was meant to use them:\n  "
                      + orphans.joined(separator: "\n  "))
    }

    // PLACEHOLDER PARITY for the chrome. A translation whose format slots don't match its
    // English source is a bug the runtime cannot fix: String(format:) will read the wrong
    // argument, print garbage, or crash. Same contract as the Lua half (i18n_parity.lua):
    // the multiset must match, and the ORDER may only change when the translation says so
    // with positional markers (%1$@ / %2$@), which String(format:) supports natively.
    func testEveryChromeTranslationKeepsItsPlaceholders() throws {
        let root = repoRoot()
        guard let data = FileManager.default.contents(atPath: root + "/app/i18n/zh-Hans.json"),
              let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return XCTFail("missing or invalid zh-Hans.json")
        }
        // Strings.t("key", default: "English %@ source")
        let literal = try NSRegularExpression(
            pattern: #"Strings\.t\(\s*"([^"\\]+)"\s*,\s*default:\s*"((?:[^"\\]|\\.)*)"#)
        // Strings.plural("key", n, one: "...", other: "...") has a DIFFERENT signature -- no
        // `default:` label. Folding it into the regex above as `(?:t|plural)` therefore matched
        // NOTHING, and every Swift plural template was silently excluded from placeholder
        // parity and the numbering rule. Match its real shape, and check BOTH forms.
        let plural = try NSRegularExpression(
            pattern: #"Strings\.plural\(\s*"([^"\\]+)"\s*,[^)]*?one:\s*"((?:[^"\\]|\\.)*)"\s*,\s*other:\s*"((?:[^"\\]|\\.)*)""#)

        var broken: [String] = [], checked = 0
        let enumerator = FileManager.default.enumerator(atPath: root + "/app")
        while let rel = enumerator?.nextObject() as? String {
            guard rel.hasSuffix(".swift"),
                  let raw = try? String(contentsOfFile: root + "/app/" + rel, encoding: .utf8)
            else { continue }
            let src = codeOnly(raw)
            let ns = src as NSString
            for m in literal.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                let en  = ns.substring(with: m.range(at: 2))
                checked += 1
                // HOUSE RULE: 2+ slots must be NUMBERED (%1$@ / %2$@) -- in the source, so a
                // translator can always reorder, and in the translation, so it stays
                // reorderable. One slot needs no number: there is nothing to reorder.
                if let why = unnumbered(en) { broken.append("\(key) (source): \(why)") }
                guard let zh = catalog[key] as? String else { continue }   // absence is the other test
                if let why = unnumbered(zh) { broken.append("\(key) (zh): \(why)") }
                if let why = placeholderMismatch(en, zh) { broken.append("\(key): \(why)") }
            }
            // plurals: both English forms must obey the same rules, and each catalog form
            // (a {one,other} object) must match its own source form.
            for m in plural.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                let forms = ["one": ns.substring(with: m.range(at: 2)),
                             "other": ns.substring(with: m.range(at: 3))]
                let zhForms = catalog[key] as? [String: String]
                for (name, en) in forms {
                    checked += 1
                    if let why = unnumbered(en) { broken.append("\(key).\(name) (source): \(why)") }
                    guard let zh = zhForms?[name] else { continue }
                    if let why = unnumbered(zh) { broken.append("\(key).\(name) (zh): \(why)") }
                    if let why = placeholderMismatch(en, zh) { broken.append("\(key).\(name): \(why)") }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "no chrome templates were compared")
        XCTAssertTrue(broken.isEmpty,
                      "\(broken.count) translation(s) do not match their source's format slots "
                      + "and will render wrong (or crash String(format:)):\n  "
                      + broken.joined(separator: "\n  "))
    }

    /// The conversion specifiers in a format string, in order, plus whether any slot names
    /// its argument positionally. `%%` is an escape, not a slot.
    private func formatSpecs(_ s: String) -> (specs: [Character], positional: Bool, plain: Int) {
        var specs: [Character] = [], positional = false, plain = 0
        let c = Array(s)
        var i = 0
        while i < c.count {
            guard c[i] == "%" else { i += 1; continue }
            if i + 1 < c.count, c[i + 1] == "%" { i += 2; continue }     // escaped percent
            var j = i + 1
            var digits = ""
            while j < c.count, c[j].isNumber { digits.append(c[j]); j += 1 }
            if j < c.count, c[j] == "$", !digits.isEmpty {               // positional marker
                positional = true
                j += 1
            } else {
                plain += 1                                               // an unnumbered slot
                j = i + 1                                                // that was width, not a slot
            }
            while j < c.count, "-+ #0".contains(c[j]) { j += 1 }         // flags
            while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }   // width.precision
            if j < c.count, c[j].isLetter || c[j] == "@" { specs.append(c[j]); j += 1 }
            i = j
        }
        return (specs, positional, plain)
    }

    /// A template with 2+ slots must number them, so any locale can reorder. With a single
    /// slot there is nothing to reorder and a number is only noise.
    private func unnumbered(_ tpl: String) -> String? {
        let s = formatSpecs(tpl)
        // MIXED is worse than unnumbered: String(format:) is UNDEFINED with a format string
        // that mixes positional and non-positional specifiers (it can read the wrong vararg
        // or crash), and Lua's formatter refuses it outright. Never let one through.
        if s.positional && s.plain > 0 {
            return "MIXES positional (%1$@) and plain (%@) specifiers -- number ALL of them"
        }
        guard s.specs.count >= 2, !s.positional else { return nil }
        return "has \(s.specs.count) slots but no positional markers -- write %1$@ / %2$@ "
             + "so a locale can reorder them"
    }

    /// nil when `zh` can safely stand in for `en`.
    private func placeholderMismatch(_ en: String, _ zh: String) -> String? {
        let e = formatSpecs(en), z = formatSpecs(zh)
        if e.specs.count != z.specs.count {
            return "placeholder count \(e.specs.count) -> \(z.specs.count)"
        }
        if z.positional {                       // order is explicit -- only the multiset must hold
            return e.specs.sorted() == z.specs.sorted() ? nil
                : "positional template changes the placeholder types"
        }
        // No markers: String(format:) is sequential, so the ORDER carries meaning.
        for (a, b) in zip(e.specs, z.specs) where a != b {
            return "reorders %\(a) and %\(b) without positional markers (use %1$@ / %2$@)"
        }
        return nil
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

    // Chinese prose that ships to a reader takes FULL-WIDTH punctuation
    // (，。：；？！). Half-width marks pressed against Chinese characters are the
    // visual signature of machine translation, and they render wrong: an ASCII
    // comma carries no advance of its own, so 词,词 sets tight where 词，词 sets
    // with the spacing the script expects.
    //
    // Why this is a gate rather than a style note. A hand pass fixed the feature
    // catalogs once; two commits later a new Settings section shipped half-width
    // again, because nothing checked and the surrounding file was already mixed.
    // Convention that is not machine-checked decays back to whatever the last
    // author happened to type -- which is exactly what the audit found.
    //
    // Scope, deliberately narrow. Only a mark ADJACENT to a Chinese character is
    // flagged, so paths (feature.json), versions (1.0.0), domains (github.com),
    // times (09:00), format strings (%Y/%m/%d %H:%M) and embedded English
    // samples ("Monday, June 23, 2026") are all untouched. That does mean a
    // sentence ending on a Latin token slips through -- accepted: a gate that
    // cries wolf gets deleted, and this one has zero false positives against the
    // real corpus.
    func testChineseCatalogsUseFullWidthPunctuation() throws {
        let root = repoRoot()
        // Half-width mark with a CJK ideograph on either side of it.
        let offender = try NSRegularExpression(
            pattern: #"[\x{4e00}-\x{9fff}][,.:;?!]|[,.:;?!][\x{4e00}-\x{9fff}]"#)

        var catalogs = [root + "/app/i18n/zh-Hans.json"]
        let featureDir = root + "/app/features"
        for id in (try? FileManager.default.contentsOfDirectory(atPath: featureDir)) ?? [] {
            let p = featureDir + "/" + id + "/i18n/zh-Hans.json"
            if FileManager.default.fileExists(atPath: p) { catalogs.append(p) }
        }
        XCTAssertGreaterThan(catalogs.count, 1, "found no feature catalogs to check")

        var offenders: [String] = []
        var checked = 0
        for path in catalogs {
            guard let data = FileManager.default.contents(atPath: path),
                  let catalog = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return XCTFail("missing or invalid \(path)") }
            let label = path.replacingOccurrences(of: root + "/", with: "")
            for (key, value) in catalog {
                guard let text = value as? String else { continue }
                checked += 1
                let range = NSRange(text.startIndex..., in: text)
                guard let hit = offender.firstMatch(in: text, range: range),
                      let r = Range(hit.range, in: text) else { continue }
                offenders.append("\(label) [\(key)]: ...\(text[r])... in \"\(text.prefix(60))\"")
            }
        }
        XCTAssertGreaterThan(checked, 0, "no strings were examined -- the gate did not run")
        XCTAssertTrue(offenders.isEmpty,
                      "\(offenders.count) Chinese string(s) use half-width punctuation next to "
                      + "Chinese text; use ，。：；？！ (、 between list items, … for an "
                      + "ellipsis):\n"
                      + offenders.sorted().prefix(20).joined(separator: "\n"))
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
