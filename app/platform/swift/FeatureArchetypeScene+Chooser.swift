import SwiftUI

// Chooser / palette archetype -- one of the FeatureArchetype scenes (the core
// enum + dispatch + shared `heartbeat` live in FeatureArchetypeAnimation.swift).

/// One sample row in a chooser: a faux glyph, a bold primary label, and a
/// secondary detail. For window_switcher that's app + window title (two rows can
/// share an app -- the point vs the macOS switcher); for clipboard_history it's
/// the entry kind + the copied text.
struct ChooserRow {
    let glyph: String   // SF Symbol standing in for the per-row icon
    let primary: String
    let secondary: String
}

// DESIGN NOTE (the shape this archetype proves): the MOTION (pop-in / step /
// enter) is shared across features, but the CONTENT is per-feature (window names
// vs clipboard entries vs commands), passed in as a `ChooserSample`. So a new
// chooser feature contributes ~3 lines of sample data, not a whole animation.
// Six features ride this one scene (window_switcher, clipboard_history,
// command_palette, tab_switcher, site_switcher, text_actions). Move the sample
// into the Lua manifest once the shape sticks.

/// The per-feature content a chooser scene renders: a query placeholder and a
/// few sample rows. This is the ONLY thing that differs between chooser features
/// -- the motion is shared (see ChooserArchetypeScene).
struct ChooserSample {
    let query: String
    let rows: [ChooserRow]

    /// window_switcher: same app, different windows -- what Cmd-Tab collapses.
    static let windows = ChooserSample(
        query: "switch to a window...",
        rows: [
            .init(glyph: "chevron.left.forwardslash.chevron.right", primary: "Code",   secondary: "Project A"),
            .init(glyph: "chevron.left.forwardslash.chevron.right", primary: "Code",   secondary: "Project B"),
            .init(glyph: "folder",                                  primary: "Finder", secondary: "Downloads"),
        ])

    /// clipboard_history: recent copies, newest first, by kind.
    static let clipboard = ChooserSample(
        query: "paste from history...",
        rows: [
            .init(glyph: "link",            primary: "github.com/...", secondary: "just now"),
            .init(glyph: "text.alignleft",  primary: "Refactor the seam", secondary: "2m ago"),
            .init(glyph: "curlybraces",     primary: "{ \"api\": 1 }",  secondary: "5m ago"),
        ])

    /// command_palette: fuzzy-run any action of any enabled feature -- rows are
    /// commands, the secondary names the owning feature (the cross-feature reach).
    static let commands = ChooserSample(
        query: "run a command...",
        rows: [
            .init(glyph: "rectangle.lefthalf.inset.filled", primary: "Snap Left",          secondary: "Window Snap"),
            .init(glyph: "doc.on.clipboard",                primary: "Paste as Plain Text", secondary: "Plain Paste"),
            .init(glyph: "moon.zzz",                        primary: "Sleep Now",           secondary: "Sleep Schedule"),
        ])

    /// tab_switcher: jump to any open browser tab by title -- across windows, the
    /// way the window switcher does it for apps. Secondary is the site/host.
    static let tabs = ChooserSample(
        query: "switch to a tab...",
        rows: [
            .init(glyph: "globe",            primary: "Pull Request #42", secondary: "github.com"),
            .init(glyph: "doc.richtext",     primary: "Hammerdeck Docs",  secondary: "localhost"),
            .init(glyph: "play.rectangle",   primary: "Build Logs",       secondary: "ci.example.com"),
        ])

    /// site_switcher: pick a favorite site to open. Secondary is the URL host.
    static let sites = ChooserSample(
        query: "open a site...",
        rows: [
            .init(glyph: "chevron.left.forwardslash.chevron.right", primary: "GitHub",   secondary: "github.com"),
            .init(glyph: "envelope",                                primary: "Gmail",    secondary: "mail.google.com"),
            .init(glyph: "calendar",                                primary: "Calendar", secondary: "calendar.google.com"),
        ])

    /// text_actions: act on the selected text -- the feature copies the
    /// selection then pops THIS picker (dictionary lookup, case changes, a
    /// calculator); URLs open directly without the menu. A chooser, not a single
    /// transform, so its preview is the menu (rows = the offered actions).
    static let textActions = ChooserSample(
        query: "act on selection...",
        rows: [
            .init(glyph: "book",       primary: "Dictionary", secondary: "look up"),
            .init(glyph: "textformat", primary: "UPPERCASE",  secondary: "change case"),
            .init(glyph: "function",   primary: "Calculate",  secondary: "evaluate"),
        ])
}

/// A stylized chooser panel: it pops in, a selection highlight steps down the
/// result rows (arrow-key navigation), the chosen row flashes (enter), and it
/// loops. Plays only while `playing` (hover); at rest it shows a calm first
/// frame so the grid isn't 20 things moving at once.
struct ChooserArchetypeScene: View {
    let sample: ChooserSample
    let playing: Bool

    private var rows: [ChooserRow] { sample.rows }
    private var rowCount: Int { rows.count }

    @State private var step = 0   // advances while playing; selected = step % rowCount

    // Guard the modulo: the sample comment invites new chooser features, and an
    // empty `rows` would otherwise divide by zero.
    private var selected: Int { rowCount == 0 ? 0 : step % rowCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            queryRow
            ForEach(0..<rowCount, id: \.self) { i in
                resultRow(i)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.15), lineWidth: 1)
        )
        .scaleEffect(playing ? 1 : 0.97)
        .opacity(playing ? 1 : 0.9)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        .heartbeat(0.85, active: playing) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { step += 1 }
        }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to a clean first frame at rest
        }
    }

    private var queryRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(sample.query)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            // a blinking caret while active
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 8)
                .opacity(playing && step % 2 == 0 ? 1 : 0.2)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 1)
    }

    private func resultRow(_ i: Int) -> some View {
        let row = rows[i]
        let isSel = playing && i == selected
        return HStack(spacing: 5) {
            Image(systemName: row.glyph)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(isSel ? Color.accentColor : .secondary)
                .frame(width: 11)
            // primary (bold) + secondary detail. For windows: two rows can share
            // the primary (app) with distinct secondaries (window) -- exactly
            // what the system switcher collapses into one entry.
            Text(row.primary)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(row.secondary)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isSel ? 0.18 : 0))
        )
        // selected row gets a tiny "enter" pop
        .scaleEffect(isSel ? 1.03 : 1, anchor: .leading)
    }
}
