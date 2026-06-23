// The single Swift source for "key/mods -> display glyph". Used directly by the
// AppKit HUD panels (ChordHintPanel, WindowModeHUDPanel, HyperHintPanel) and,
// via the thin free-function wrappers in FeatureChrome.swift (keyGlyph/
// modGlyphs/shortcutGlyph), by the SwiftUI feature views and ShortcutRecorder.
// One table, one modifier order, so none of those surfaces can drift.
// (The Lua side keeps its own copy in registry.lua's specGlyph -- the
// irreducible cross-language minimum; surface parity is asserted in tests.)

import AppKit

enum KeyGlyphs {
    /// A single key name -> its display glyph. Named keys (arrows, space, esc,
    /// ...) map to their symbol; a lone character upcases; anything longer
    /// (already a glyph or a composite like "fn") passes through untouched.
    static func glyph(_ k: String) -> String {
        let named: [String: String] = [
            "left": "\u{2190}", "right": "\u{2192}", "up": "\u{2191}", "down": "\u{2193}",
            "return": "\u{21A9}", "enter": "\u{21A9}", "space": "\u{2423}",
            "tab": "\u{21E5}", "delete": "\u{232B}", "backspace": "\u{232B}",
            "escape": "\u{238B}", "esc": "\u{238B}",
        ]
        if let g = named[k.lowercased()] { return g }
        return k.count == 1 ? k.uppercased() : k
    }

    /// Modifier glyphs in the canonical display order: ctrl, alt, shift, cmd.
    /// Accepts both short and long spellings (ctrl/control, alt/option,
    /// cmd/command) so any binding source can feed it.
    static func modifiers(_ mods: [String]) -> String {
        let set = Set(mods.map { $0.lowercased() })
        var s = ""
        if set.contains("ctrl") || set.contains("control") { s += "\u{2303}" }
        if set.contains("alt") || set.contains("option")   { s += "\u{2325}" }
        if set.contains("shift")                            { s += "\u{21E7}" }
        if set.contains("cmd") || set.contains("command")   { s += "\u{2318}" }
        return s
    }

    /// A full chord prefix: modifier glyphs followed by the key glyph.
    static func prefix(_ mods: [String], _ key: String) -> String {
        modifiers(mods) + glyph(key)
    }
}
