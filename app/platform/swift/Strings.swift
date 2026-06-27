import Foundation

// Swift-side reader for the SAME JSON catalogs the Lua i18n module uses
// (app/i18n/<locale>.json), so host chrome and feature text share one source of
// truth. English is the inline source: callers pass the English string as
// `default`, and only non-en locales ship a catalog (a missing key falls back to
// `default`, never to a raw key the user would see).
//
// Loaded once; a locale change applies on relaunch (the chosen macOS-norm
// behavior). Mirrors resourceRoot() path-loading rather than Bundle.module, to
// match how the rest of the app/ tree is located at runtime.
enum Strings {
    /// Localize `key`, falling back to the inline English `default`. Interpolate
    /// with String(format:) over the result so placeholders match across locales.
    static func t(_ key: String, default def: String) -> String {
        catalog.strings[key] ?? def
    }

    /// Pick a plural TEMPLATE for `count`. `one`/`other` are the inline English
    /// source; a catalog `{one,other}` entry overrides them. The caller does the
    /// String(format:) (uniform with `t`).
    static func plural(_ key: String, _ count: Int, one: String, other: String) -> String {
        let forms = catalog.plurals[key] ?? ["one": one, "other": other]
        return forms[category(count)] ?? forms["other"] ?? other
    }

    /// CLDR plural category for the resolved locale. English splits one/other;
    /// the CJK locales we ship (zh-Hans) collapse to a single category.
    static func category(_ count: Int) -> String {
        if resolved == "en" { return count == 1 ? "one" : "other" }
        return "other"
    }

    private static let resolved = LocaleResolver.current

    // Split into two Sendable maps (string entries vs {one,other} plural entries)
    // so the cached catalog is concurrency-safe -- a bare [String: Any] is not.
    private struct Catalog: Sendable {
        var strings: [String: String] = [:]
        var plurals: [String: [String: String]] = [:]
    }

    private static let catalog: Catalog = {
        guard resolved != "en" else { return Catalog() }
        let path = resourceRoot() + "/app/i18n/\(resolved).json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Catalog() }
        var c = Catalog()
        for (key, value) in obj {
            if let s = value as? String { c.strings[key] = s }
            else if let d = value as? [String: String] { c.plurals[key] = d }
        }
        return c
    }()
}
