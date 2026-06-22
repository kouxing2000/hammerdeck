import SwiftUI

// Per-action preview CARDS for the Settings toggle rows -- the per-action analog
// of a feature's gallery card, driven by the short `preview` token an option
// declares. OptionPreviewScene is referenced from SettingsView; the minis it
// dispatches to are file-local. The core enum + dispatch live in
// FeatureArchetypeAnimation.swift.

/// A full animated preview CARD for one action, rendered above its Show-X toggle
/// (the per-action analog of a feature's gallery card). Driven by the short token
/// the option declares (`preview = "case:upper"` / "calc" / "dict" / "ai"). Plays
/// only while `playing` (card hover); at rest it shows the calm first frame.
struct OptionPreviewScene: View {
    let token: String
    let playing: Bool

    @ViewBuilder var body: some View {
        switch token {
        case "case:lower": CaseChangeMini(playing: playing, upper: false)
        case "case:upper": CaseChangeMini(playing: playing, upper: true)
        case "calc":       CalcMini(playing: playing)
        case "dict":       DictMini(playing: playing)
        // Each AI action gets its OWN before->after sample reflecting its job.
        case "ai:refine":   AITransformMini(playing: playing, before: "teh qiuck",    after: "The quick")
        case "ai:enrich":   AITransformMini(playing: playing, before: "a dog",        after: "a fluffy dog")
        case "ai:complete": AITransformMini(playing: playing, before: "Once upon a",  after: "Once upon a time")
        case "ai:summary":  AITransformMini(playing: playing, before: "long, wordy…", after: "in short")
        case "ai:translate": AITransformMini(playing: playing, before: "hello",       after: "bonjour")
        case "ai:freeask":  AITransformMini(playing: playing, before: "hey",          after: "Greetings")
        default:           Color.clear
        }
    }
}

/// A selected line whose case flips (the change-case transform), with a small
/// pop on the change. At rest shows the "before" case.
private struct CaseChangeMini: View {
    let playing: Bool
    let upper: Bool
    @State private var done = false

    private var before: String { upper ? "make it loud" : "MAKE IT QUIET" }
    private var after: String { upper ? "MAKE IT LOUD" : "make it quiet" }

    var body: some View {
        Text(done ? after : before)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
            .scaleEffect(done ? 1.05 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
            .heartbeat(1.1, active: playing) { done.toggle() }
            .onChange(of: playing) { if !$0 { done = false } }
    }
}

/// A selected expression that gets REPLACED IN PLACE by `expr=result` -- exactly
/// what Calculate pastes back over the selection in an editor. Rest shows the
/// selected expression; playing replaces it with the evaluated form.
private struct CalcMini: View {
    let playing: Bool
    @State private var solved = false

    var body: some View {
        Text(solved ? "108" : "12 × 9")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
            .scaleEffect(solved ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: solved)
            .heartbeat(1.1, active: playing) { solved.toggle() }
            .onChange(of: playing) { if !$0 { solved = false } }
    }
}

/// A word with its definition fading in -- the Dictionary look-up action.
private struct DictMini: View {
    let playing: Bool
    @State private var shown = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 17)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("ubiquitous").font(.system(size: 12, weight: .semibold))
                Text("present everywhere")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .opacity(shown ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.45), value: shown)
        .heartbeat(1.4, active: playing) { shown.toggle() }
        .onChange(of: playing) { if !$0 { shown = false } }
    }
}

/// A selected line REPLACED IN PLACE by an AI rewrite -- what every AI action
/// does to the selection, but each passes its own before/after so the preview
/// reflects that action's job (refine/enrich/complete/summarize/translate/ask).
/// Rest shows the original selection; playing settles on the rewrite, sparkle lit.
private struct AITransformMini: View {
    let playing: Bool
    let before: String
    let after: String
    @State private var done = false

    var body: some View {
        HStack(spacing: 6) {
            Text(done ? after : before)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
                .scaleEffect(done ? 1.03 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: done)
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(done ? Color.accentColor : .secondary)
                .scaleEffect(done ? 1.15 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: done)
        }
        .heartbeat(1.2, active: playing) { done.toggle() }
        .onChange(of: playing) { if !$0 { done = false } }
    }
}
