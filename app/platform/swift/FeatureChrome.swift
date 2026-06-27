import SwiftUI

// Shared presentation helpers for the three feature-facing views -- the
// Shortcut Map (key dimension), the Automation Timeline (time dimension), and
// the Feature Gallery (discovery). Kept in one place so a feature's category
// color, glyph, and compact shortcut render identically wherever it appears.

/// The accent color for a manifest category. Drives category dots/tags across
/// the views; falls back to gray for anything uncategorized.
func categoryColor(_ category: String) -> Color {
    switch category {
    case "health":       return .green
    case "appearance":   return .purple
    case "productivity": return .blue
    case "platform":     return .orange
    default:             return .gray
    }
}

/// Usage time format ("<1m" / "Nm" / "Hh Mm"), shared by the desktop usage
/// widget and the Usage report so the two renderings can never drift.
func usageTimeString(_ secs: Double) -> String {
    if secs < 60 { return "<1m" }
    let h = Int(secs) / 3600
    let m = (Int(secs) % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

/// Localized display label for a manifest category (the Settings sidebar section
/// header). Unknown categories fall back to their capitalized raw value.
func categoryLabel(_ category: String) -> String {
    switch category {
    case "health":       return Strings.t("category.health", default: "Health")
    case "appearance":   return Strings.t("category.appearance", default: "Appearance")
    case "productivity": return Strings.t("category.productivity", default: "Productivity")
    case "platform":     return Strings.t("category.platform", default: "Platform")
    case "general":      return Strings.t("category.general", default: "General")
    default:             return category.capitalized
    }
}

/// An SF Symbol glyph for a manifest category. Features don't declare their own
/// icons yet (Gallery spec, open question 1) -- v1 derives one from category.
func categoryIcon(_ category: String) -> String {
    switch category {
    case "health":       return "heart.fill"
    case "appearance":   return "paintbrush.fill"
    case "productivity": return "bolt.fill"
    case "platform":     return "gearshape.2.fill"
    default:             return "puzzlepiece.fill"
    }
}

/// The "Works when…" axis -- the PRIMARY way features are grouped (Gallery
/// sections + Tour order). Mirrors the manifest `context` field; answers "when
/// does this apply" rather than "what domain is it," which matters more to a new
/// user. Orthogonal to `category` (the domain tag).
enum FeatureContext: String, CaseIterable {
    case textField, window, web, anywhere, automatic

    init(_ raw: String) { self = FeatureContext(rawValue: raw) ?? .anywhere }

    /// Section header / filter-chip label.
    var title: String {
        switch self {
        case .textField: return Strings.t("context.textField.title", default: "Text editing")
        case .window:    return Strings.t("context.window.title", default: "Windows")
        case .web:       return Strings.t("context.web.title", default: "Web browser")
        case .anywhere:  return Strings.t("context.anywhere.title", default: "Anywhere")
        case .automatic: return Strings.t("context.automatic.title", default: "Automatic")
        }
    }

    /// The scenario line shown on a Tour slide -- "when does this kick in."
    var scenario: String {
        switch self {
        case .textField: return Strings.t("context.textField.scenario", default: "When typing in a text field")
        case .window:    return Strings.t("context.window.scenario", default: "With a window focused")
        case .web:       return Strings.t("context.web.scenario", default: "In your web browser")
        case .anywhere:  return Strings.t("context.anywhere.scenario", default: "Anytime, anywhere")
        case .automatic: return Strings.t("context.automatic.scenario", default: "Runs on its own")
        }
    }

    var icon: String {
        switch self {
        case .textField: return "character.cursor.ibeam"
        case .window:    return "macwindow"
        case .web:       return "globe"
        case .anywhere:  return "sparkles"
        case .automatic: return "clock.arrow.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .textField: return .blue
        case .window:    return .teal
        case .web:       return .indigo
        case .anywhere:  return .orange
        case .automatic: return .purple
        }
    }

    /// Stable display order (declaration order) for sections and the Tour.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

/// Human label for a manifest `requires` token (the precondition badge).
func requirementLabel(_ r: String) -> String {
    switch r {
    case "accessibility": return Strings.t("req.accessibility", default: "Needs Accessibility")
    default:              return String(format: Strings.t("req.generic", default: "Needs %@"), r.capitalized)
    }
}

// Compact glyph string for a trigger (e.g. "⌃⌥⌘←"). Thin wrappers over
// `KeyGlyphs` (the single Swift glyph source) for callers that want the
// free-function form (the SwiftUI views, ShortcutRecorder, StatusBar); the
// AppKit HUD panels call KeyGlyphs directly. Mirrors triggers.lua's `glyph`.
func keyGlyph(_ key: String) -> String { KeyGlyphs.glyph(key) }

func modGlyphs(_ mods: [String]) -> String { KeyGlyphs.modifiers(mods) }

/// The compact glyph for a trigger spec, or "" when there is none.
func shortcutGlyph(_ t: TriggerSpec?) -> String {
    guard let t else { return "" }
    switch t.type {
    case "hotkey":   return modGlyphs(t.mods) + keyGlyph(t.key)
    case "chord":    return modGlyphs(t.mods) + keyGlyph(t.key) + " "
                          + t.follows.map(keyGlyph).joined(separator: " ")
    // {n}/{v} tokens shared verbatim with Lua triggers.glyph (see the note there)
    // -- same catalog keys, identical English defaults, so glyph parity holds.
    case "schedule":
        if let n = t.everyMin {
            return Strings.t("glyph.every", default: "every {n}m").replacingOccurrences(of: "{n}", with: String(n))
        }
        return Strings.t("glyph.at", default: "at {v}").replacingOccurrences(of: "{v}", with: t.at ?? "")
    case "event":    return Strings.t("glyph.on", default: "on {v}").replacingOccurrences(of: "{v}", with: t.event ?? "")
    default:         return ""
    }
}
