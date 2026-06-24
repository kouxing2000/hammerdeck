import SwiftUI

// Text effects: typing the clipboard out as keystrokes (plain_paste's "type"
// action) and the in-place text transform (case change / strip formatting).
// Part of the FeatureArchetype scene set; the core enum + dispatch live in
// FeatureArchetypeAnimation.swift.

// MARK: - Type-as-keystrokes effect (plain_paste, "type" action)

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
        // NOTE: .caseChange is currently UNROUTED -- text_actions now maps to
        // .chooser(.textActions) (it pops a menu, not a single transform), so no
        // live feature produces this sample. Kept for a future direct
        // change-case action; the Kind case is still needed for exhaustiveness.
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
