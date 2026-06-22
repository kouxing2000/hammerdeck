// Shared key-glyph mapping for the informational HUD panels (ChordHintPanel,
// WindowModeHUDPanel). One place that turns a binding's key/mods into the
// pretty glyphs a cheat-sheet shows -- so the two panels can't drift.

import AppKit

enum KeyGlyphs {
    /// A single key name -> its display glyph. Named keys (arrows, space, esc,
    /// ...) map to their symbol; a lone character upcases; anything longer
    /// (already a glyph or a composite like "fn") passes through untouched.
    static func glyph(_ k: String) -> String {
        let named: [String: String] = [
            "left": "\u{2190}", "right": "\u{2192}", "up": "\u{2191}", "down": "\u{2193}",
            "return": "\u{23CE}", "enter": "\u{23CE}", "space": "\u{2423}",
            "tab": "\u{21E5}", "delete": "\u{232B}", "backspace": "\u{232B}",
            "escape": "\u{238B}", "esc": "\u{238B}",
        ]
        if let g = named[k.lowercased()] { return g }
        return k.count == 1 ? k.uppercased() : k
    }

    /// Modifier glyphs in the canonical display order: ctrl, alt, shift, cmd.
    static func modifiers(_ mods: [String]) -> String {
        let order: [(String, String)] = [("ctrl", "\u{2303}"), ("alt", "\u{2325}"),
                                         ("shift", "\u{21E7}"), ("cmd", "\u{2318}")]
        let set = Set(mods.map { $0.lowercased() })
        return order.filter { set.contains($0.0) }.map(\.1).joined()
    }

    /// A full chord prefix: modifier glyphs followed by the key glyph.
    static func prefix(_ mods: [String], _ key: String) -> String {
        modifiers(mods) + glyph(key)
    }
}
