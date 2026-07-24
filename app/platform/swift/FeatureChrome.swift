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

/// An SF Symbol glyph for a manifest category -- the shared fallback used when a
/// feature declares no `icon` of its own (and still the tint source everywhere).
func categoryIcon(_ category: String) -> String {
    switch category {
    case "health":       return "heart.fill"
    case "appearance":   return "paintbrush.fill"
    case "productivity": return "bolt.fill"
    case "platform":     return "gearshape.2.fill"
    default:             return "puzzlepiece.fill"
    }
}

/// The SF Symbol for a feature: its own declared `icon` if present, else the
/// shared per-category glyph. The single resolver every surface (menubar,
/// Settings list, Gallery card) calls, so a feature's glyph can never drift
/// between them.
func featureIcon(_ feature: FeatureInfo) -> String {
    feature.icon ?? categoryIcon(feature.category)
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

// MARK: - Capabilities

/// How a declared capability is presented: a short name, a glyph, and one line
/// saying what it actually lets the feature do.
///
/// The wording is deliberately concrete ("Reads your open browser tabs", not
/// "Browser access"): the whole point of surfacing these is that a reader can
/// judge the reach without opening the code, and a vague label defeats that as
/// thoroughly as showing nothing.
///
/// `requires` and `capabilities` look similar but answer opposite questions and
/// are kept apart on purpose: `requires` is what the FEATURE needs FROM macOS
/// before it can work (a grant you may have to give), while a capability is what
/// the feature may do TO your machine once running. Merging them into one badge
/// row would blur "grant this to proceed" with "this is what it can reach".
struct CapabilityInfo {
    let label: String
    let symbol: String
    let detail: String
}

/// Presentation for a capability, or nil when this build has no wording for it.
///
/// Returning an Optional rather than a "looks like a fallback" sentinel is
/// deliberate: the parity test needs to ask "is this tier presented?" and any
/// sniffing answer is wrong. (The first cut compared the label against the
/// capitalized id, which flags `network` -> "Network" as unpresented -- a
/// correctly-presented tier failing its own guard.) Now the question has a
/// direct answer and cannot be gamed by a label that happens to match its id.
func capabilityPresentation(_ c: String) -> CapabilityInfo? {
    switch c {
    case "input":
        return CapabilityInfo(
            label: Strings.t("cap.input", default: "Keyboard input"),
            symbol: "keyboard",
            detail: Strings.t("cap.input.detail",
                              default: "Types and presses keys in whatever app is focused."))
    case "network":
        return CapabilityInfo(
            label: Strings.t("cap.network", default: "Network"),
            symbol: "network",
            detail: Strings.t("cap.network.detail",
                              default: "Sends and receives data over the internet."))
    case "power":
        return CapabilityInfo(
            label: Strings.t("cap.power", default: "Sleep & lock"),
            symbol: "powersleep",
            detail: Strings.t("cap.power.detail",
                              default: "Can sleep the display or the Mac, and lock the screen."))
    case "browser":
        return CapabilityInfo(
            label: Strings.t("cap.browser", default: "Browser"),
            symbol: "safari",
            detail: Strings.t("cap.browser.detail",
                              default: "Reads your open tabs -- their titles and addresses -- and can switch between them."))
    case "files":
        return CapabilityInfo(
            label: Strings.t("cap.files", default: "Files"),
            symbol: "folder",
            detail: Strings.t("cap.files.detail",
                              default: "Reads and writes files outside its own storage folder."))
    case "commands":
        return CapabilityInfo(
            label: Strings.t("cap.commands", default: "Other features"),
            symbol: "command",
            detail: Strings.t("cap.commands.detail",
                              default: "Can list and run the actions of your other enabled features."))
    default:
        return nil
    }
}

/// Presentation for the UI, which must always render SOMETHING: an unpresented
/// capability degrades to its raw id plus a generic line rather than vanishing.
/// Showing LESS reach than a feature actually has is the one failure mode this
/// surface must not have -- a missing row reads as "touches nothing", which is
/// precisely the false reassurance the capability work exists to prevent. The
/// parity test above keeps this path from becoming the normal one.
func capabilityInfo(_ c: String) -> CapabilityInfo {
    capabilityPresentation(c)
        ?? CapabilityInfo(label: c.capitalized, symbol: "questionmark.circle",
                          detail: Strings.t("cap.unknown.detail",
                                            default: "An additional capability."))
}

/// Declaration order is alphabetical in feature.json; show them in a stable
/// severity-ish order instead, so the reach that matters most reads first.
func sortedCapabilities(_ caps: [String]) -> [String] {
    let rank = ["input": 0, "browser": 1, "network": 2, "files": 3, "power": 4, "commands": 5]
    return caps.sorted { (rank[$0] ?? 99, $0) < (rank[$1] ?? 99, $1) }
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

// MARK: - Shared chrome views

/// The compact shortcut-glyph pill (e.g. ⌃⌥⌘← on a soft gray rounded rect).
/// Rendered identically wherever a feature's bound shortcut is shown -- the
/// Dashboard, the Tour, and the Gallery card footer all use this so the pill can
/// never drift. (The Shortcut Map's draggable swap cell is intentionally NOT
/// this -- it carries hover/drag/shadow chrome of its own.)
struct ShortcutPill: View {
    let glyph: String
    var body: some View {
        Text(glyph)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.14)))
    }
}

/// A tappable "<requirement> — Grant" badge for an unmet precondition (e.g.
/// Accessibility): tapping opens System Settings to grant it. Owns only the
/// chrome (lock.shield + orange capsule); the caller passes its own surface's
/// localized `label`/`help` and the grant `action`, so each view keeps its own
/// i18n keys while the look stays unified.
struct RequirementBadge: View {
    let label: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "lock.shield")
                .font(.caption2)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
