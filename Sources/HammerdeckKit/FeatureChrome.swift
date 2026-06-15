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

// Compact glyph string for a trigger (e.g. "⌃⌥⌘←"). Mirrors registry.lua's
// specGlyph; the modifier order here is the macOS display convention (⌃⌥⇧⌘).
private let kKeyGlyphs: [String: String] = [
    "tab": "⇥", "return": "↩", "enter": "↩", "space": "␣",
    "delete": "⌫", "backspace": "⌫", "escape": "⎋", "esc": "⎋",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
]

func keyGlyph(_ key: String) -> String {
    if let g = kKeyGlyphs[key.lowercased()] { return g }
    return key.count == 1 ? key.uppercased() : key
}

func modGlyphs(_ mods: [String]) -> String {
    let has = Set(mods.map { $0.lowercased() })
    var s = ""
    if has.contains("ctrl") || has.contains("control") { s += "⌃" }
    if has.contains("alt") || has.contains("option")   { s += "⌥" }
    if has.contains("shift")                            { s += "⇧" }
    if has.contains("cmd") || has.contains("command")   { s += "⌘" }
    return s
}

/// The compact glyph for a trigger spec, or "" when there is none.
func shortcutGlyph(_ t: TriggerSpec?) -> String {
    guard let t else { return "" }
    switch t.type {
    case "hotkey":   return modGlyphs(t.mods) + keyGlyph(t.key)
    case "chord":    return modGlyphs(t.mods) + keyGlyph(t.key) + " "
                          + t.follows.map(keyGlyph).joined(separator: " ")
    case "schedule": return t.everyMin != nil ? "every \(t.everyMin!)m" : "at \(t.at ?? "")"
    case "event":    return "on \(t.event ?? "")"
    default:         return ""
    }
}
