import AppKit
import Carbon.HIToolbox

/// The four modifier tokens the platform accepts (long aliases included) --
/// the ONE parser behind every consumer: Carbon hotkey registration
/// (HotkeyCenter), chord prefixes (ChordCenter), CGEvent synthesis
/// (key_stroke), and the held-modifier probe. The seam functions gate on
/// `firstUnknown` and raise a Lua error (media_key's precedent), so a typo'd
/// name is rejected loudly instead of silently meaning "no modifier" -- the
/// bug class where a dropped "cmd" would bind or synthesize a LESS-modified
/// combo (cousin of window_snap's "previous" falling through to "next").
/// This is the ONE authority: the Lua layer reads it via
/// native.valid_modifiers() (triggers.validate), and the test fake's mirror
/// is pinned to it by an integration contract test.
///
/// Known NON-derived consumers (display-side, hand-rolled -- extend them too
/// if a token is ever added here, or a new modifier would bind fine but render
/// no glyph / keyEquivalent): KeyGlyphs.modifiers, StatusBar.modifierMask,
/// SettingsStore's modifier ordering.
enum KeyModifier: CaseIterable {
    case cmd, alt, ctrl, shift

    /// Every accepted token (canonical name + long alias) -> its modifier.
    /// `parse`, `validTokens`, and the native valid_modifiers export all
    /// derive from this table.
    private static let tokens: [String: KeyModifier] = [
        "cmd": .cmd, "command": .cmd,
        "alt": .alt, "option": .alt,
        "ctrl": .ctrl, "control": .ctrl,
        "shift": .shift,
    ]

    static func parse(_ name: String) -> KeyModifier? {
        tokens[name.lowercased()]
    }

    /// Every accepted token, sorted -- exported to Lua as valid_modifiers().
    static var validTokens: [String] { tokens.keys.sorted() }

    /// The first name `parse` rejects, or nil when the whole list is valid.
    static func firstUnknown(in mods: [String]) -> String? {
        mods.first { parse($0) == nil }
    }

    /// Canonical short name ("command" -> "cmd").
    var canonical: String {
        switch self {
        case .cmd:   return "cmd"
        case .alt:   return "alt"
        case .ctrl:  return "ctrl"
        case .shift: return "shift"
        }
    }

    /// Carbon flag for RegisterEventHotKey.
    var carbon: UInt32 {
        switch self {
        case .cmd:   return UInt32(cmdKey)
        case .alt:   return UInt32(optionKey)
        case .ctrl:  return UInt32(controlKey)
        case .shift: return UInt32(shiftKey)
        }
    }

    /// CGEvent flag for synthesized keystrokes.
    var cgFlag: CGEventFlags {
        switch self {
        case .cmd:   return .maskCommand
        case .alt:   return .maskAlternate
        case .ctrl:  return .maskControl
        case .shift: return .maskShift
        }
    }

    /// NSEvent flag for live-state probes (is_modifier_held).
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .cmd:   return .command
        case .alt:   return .option
        case .ctrl:  return .control
        case .shift: return .shift
        }
    }
}
