import SwiftUI

// Text effects: typing the clipboard out as keystrokes (plain_paste's "type"
// action) and the in-place text transform (case change / strip formatting).
// Part of the FeatureArchetype scene set; the core enum + dispatch live in
// FeatureArchetypeAnimation.swift.

// MARK: - Type-as-keystrokes effect (plain_paste, "type" action)

/// The content a `typeText` preview types out: the line, and the badge caption
/// naming what it is.
///
/// This is a NAMED sample like every other archetype's, not a bare string, and
/// deliberately so. When the archetype binding moved into feature.json, this one
/// case passed its sample straight through as literal content -- which meant
/// feature.json carried fixture copy (the design says payloads stay in Swift),
/// and the caption stayed hardcoded to insert_datetime's wording at the
/// dispatcher. Any second feature adopting `typeText` -- the whole point of
/// making archetypes declarative -- would have typed ITS string under a badge
/// reading "Date & time typed in". Naming the sample fixes both: uniform field
/// semantics, and the caption travels with the content it describes.
struct TypeTextSample {
    let full: String
    let caption: String

    /// insert_datetime. The line mirrors the shape of the default format preset
    /// (see `app/features/insert_datetime/lua/init.lua`) rather than its exact
    /// output -- it is an illustration, not a rendering, so it does not track the
    /// preset's seconds field.
    static let datetimeDefault = TypeTextSample(full: "06/23/2026 03:04 PM",
                                                caption: "Date & time typed in")

    /// plain_paste's "type the clipboard out" action -- the scene's own origin.
    static let clipboard = TypeTextSample(full: "Hello, clipboard",
                                          caption: "Typed as keystrokes")

    static func named(_ name: String?) -> TypeTextSample? {
        switch name {
        case "datetimeDefault": return .datetimeDefault
        case "clipboard":       return .clipboard
        default:                return nil
        }
    }
}

/// Previews plain_paste's "Type clipboard as keystrokes" action: the clipboard
/// text is typed into a document one character at a time (a blinking caret
/// trailing), with a keyboard glyph to signal it's synthesized keystrokes -- not
/// a paste. At rest the full line is shown (the calm frame). Plays only while
/// `playing` (hover).
struct TypeKeystrokesArchetypeScene: View {
    let playing: Bool

    // The typed line and the badge caption default to the clipboard-type-out
    // case (plain_paste) but are overridable so other "synthesize keystrokes"
    // features can reuse this scene (e.g. insert_datetime types a timestamp).
    var full = "Hello, clipboard"
    var caption = "Typed as keystrokes"
    let holdFrames = 6                      // pause on the full line before looping
    @State private var step = 0

    private var cycle: Int { full.count + holdFrames }
    private var shownCount: Int {
        guard playing else { return full.count }   // calm frame = fully typed
        return min(step % cycle, full.count)
    }
    private var shown: String { String(full.prefix(shownCount)) }
    private var caretOn: Bool { !playing || step % 2 == 0 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.18), lineWidth: 1))

            VStack(spacing: 7) {
                // the document being typed into
                HStack(spacing: 1) {
                    Text(shown)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: 13)
                        .opacity(caretOn ? 1 : 0.15)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.4), lineWidth: 1))

                // a keyboard glyph: these are synthesized keystrokes, not a paste
                HStack(spacing: 3) {
                    Image(systemName: "keyboard").font(.system(size: 8, weight: .bold))
                    Text(caption).font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.9)))
            }
            .padding(.horizontal, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .heartbeat(0.16, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to the fully-typed calm frame
        }
    }
}

// MARK: - Text-transform effect (text actions / plain paste)

/// The per-feature face of the text-transform effect. text_actions changes the
/// case of the selected text; plain_paste strips styling (colors / bold /
/// underline) down to plain text. Same effect family -- "selected text becomes
/// transformed text" -- so they share one scene.
struct TextTransformSample {
    enum Kind { case caseChange, stripFormat }
    let kind: Kind
    let chipGlyph: String
    let chipLabel: String

    static let caseChange  = TextTransformSample(kind: .caseChange,  chipGlyph: "textformat",  chipLabel: "Change Case")
    static let stripFormat = TextTransformSample(kind: .stripFormat, chipGlyph: "paintbrush",   chipLabel: "Plain Text")
}

/// A line of SELECTED text (accent highlight) that transforms in place: lowercase
/// pops to UPPERCASE, or styled words settle to plain. The before/after toggle is
/// the payoff -- the card shows the messy input at rest, the clean result on
/// hover. Plays only while `playing` (hover); at rest it shows the BEFORE state.
struct TextTransformArchetypeScene: View {
    let sample: TextTransformSample
    let playing: Bool

    @State private var done = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.18), lineWidth: 1))

            VStack(spacing: 7) {
                // the selected text line (highlight = it's the current selection)
                lineView
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)))
                    .scaleEffect(done ? 1.04 : 1)

                // the action being applied
                HStack(spacing: 3) {
                    Image(systemName: sample.chipGlyph).font(.system(size: 7, weight: .bold))
                    Text(sample.chipLabel).font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(done ? 0.95 : 0.55)))
            }
            .padding(.horizontal, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: done)
        .heartbeat(1.5, active: playing) { done.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { done = false }   // settle to the BEFORE (messy) state
        }
    }

    @ViewBuilder private var lineView: some View {
        switch sample.kind {
        // NOTE: no feature currently declares .caseChange -- text_actions maps to
        // chooser/textActions instead (it pops a menu, not a single transform).
        // It is no longer dead code, though: since previews became declarative it
        // is reachable by any feature writing `"sample": "caseChange"` in its
        // feature.json, with no Swift edit. Kept as an offered sample, not a
        // leftover.
        case .caseChange:
            Text(done ? "RESIZE WINDOW" : "resize window")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        case .stripFormat:
            HStack(spacing: 4) {
                Text("Refactor")
                    .fontWeight(done ? .regular : .bold)
                    .foregroundStyle(done ? .primary : Color.blue)
                Text("the").foregroundStyle(.primary)
                Text("seam")
                    .underline(!done)
                    .foregroundStyle(done ? .primary : Color.purple)
            }
            .font(.system(size: 11, weight: .medium))
        }
    }
}


// `preview.sample` name -> payload. Rationale for the split (and for returning
// nil rather than a default) lives once, on FeatureArchetype.of.
extension TextTransformSample {
    static func named(_ name: String?) -> TextTransformSample? {
        switch name {
        case "caseChange": return .caseChange
        case "stripFormat": return .stripFormat
        default: return nil
        }
    }
}
