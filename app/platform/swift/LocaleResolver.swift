import Foundation

// The single authority for "which UI language are we in". Resolved once and
// shared with Lua (via native.locale() -> adapter.locale()), so both layers
// localize against the same code (e.g. "en", "zh-Hans").
//
// Order: an in-app override (UserDefaults "hammerdeck.locale", written by the
// future language picker) wins; otherwise macOS's preferred languages are
// matched against the catalogs we actually ship; otherwise English.
enum LocaleResolver {
    static let overrideKey = "hammerdeck.locale"

    static var current: String {
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty {
            return override
        }
        let available = availableLocales()
        // preferredLocalizations does the BCP-47 match (e.g. "zh-Hans-CN" ->
        // "zh-Hans", "en-US" -> "en") and always returns a best effort.
        return Bundle.preferredLocalizations(from: available,
                                             forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    // Codes we can render: "en" (the inline source -- always available) plus
    // every app/i18n/<code>.json on disk. Keeping "en" in the set means an
    // English speaker resolves to "en" instead of being forced into the only
    // translated catalog.
    static func availableLocales() -> [String] {
        var codes = ["en"]
        let dir = resourceRoot() + "/app/i18n"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for f in files where f.hasSuffix(".json") {
                codes.append(String(f.dropLast(5)))   // strip ".json"
            }
        }
        return codes
    }
}

// The in-app language override -- what the Settings picker reads and writes. The
// empty string is the "follow the system" sentinel (the key is removed, so
// LocaleResolver falls back to macOS preferred languages). A change applies on
// relaunch (the chosen macOS-norm behavior).
enum LocalePreference {
    static let systemDefault = ""

    static var override: String {
        UserDefaults.standard.string(forKey: LocaleResolver.overrideKey) ?? systemDefault
    }

    static func set(_ code: String) {
        if code == systemDefault {
            UserDefaults.standard.removeObject(forKey: LocaleResolver.overrideKey)
        } else {
            UserDefaults.standard.set(code, forKey: LocaleResolver.overrideKey)
        }
    }

    // Picker rows: "System default" first, then every shipped catalog code shown
    // by its ENDONYM (the language's name in its own script: "English", "中文(简体)").
    static func options() -> [(code: String, label: String)] {
        var out: [(code: String, label: String)] = [(systemDefault, "System default")]
        for code in LocaleResolver.availableLocales().sorted() {
            let endonym = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            out.append((code, endonym))
        }
        return out
    }
}
