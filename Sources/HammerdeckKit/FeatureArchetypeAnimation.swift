import SwiftUI
import Combine

// Native archetype animations for the Feature Gallery -- a small, reusable set
// of looping SwiftUI "demo scenes" that SHOW what a feature does, rather than a
// hand-recorded clip per feature. Features collapse into a handful of archetypes,
// so a new feature inherits a fitting animation for free, and the scene lives in
// code (reviewable, restyle-proof) instead of a rotting asset.
//
// KEY PRINCIPLE: an archetype previews the visible EFFECT, not the trigger or
// the feature category. "Runs on a schedule" is not a preview -- a clock tells
// you nothing. So sleep/display-off show the SCREEN GOING DARK; countdown shows
// its actual progress strip. Group features by what the user SEES happen
// (a chooser pops, a window snaps, a banner slides, the screen darkens).
//
// PROOF OF CONCEPT: only the `chooser` archetype is built. The KEY shape it
// proves: the MOTION (pop-in / step / enter) is shared across features, but the
// CONTENT is per-feature (window names vs clipboard entries), passed in as a
// `ChooserSample`. So a new chooser feature contributes ~3 lines of sample data,
// not a whole animation. Five features ride this one scene (window_switcher,
// clipboard_history, command_palette, tab_switcher, site_switcher). Move the
// sample into the Lua manifest once the shape sticks.

/// The interaction shape a feature presents to the user. The Gallery plays the
/// matching looping scene, parameterized by per-feature content. `.none` = no
/// animation (feature has no visual moment worth showing; keep the static icon).
enum FeatureArchetype {
    case none
    case chooser(ChooserSample)             // a panel pops, arrow + enter (window/tab switch, palette, clipboard)
    case windowArrange(WindowArrangeSample) // a window rect rearranges: snap / resize / center (snap AND modal)
    case banner(BannerSample)               // a notification/legend pill slides in from the top edge
    // Archetypes preview the visible EFFECT, not the trigger. A clock/ring would
    // only say "this runs on a schedule" -- meaningless. So sleep & display-off
    // show the screen going dark; countdown shows its actual progress strip.
    case screenOff(ScreenOffSample) // the screen dims to black (system sleep / display off)
    case countdownStrip             // a thin progress strip depletes along the screen edge
    case pointerPulse               // a crosshair + expanding rings pulse around the cursor (locate pointer)
    case pointerFollow              // a window moves and the cursor chases it (pointer follows moved window)
    case passwordReveal             // scrambling characters lock into a strong password, then "copied"
    case chart                      // per-app focus-time bars grow into a usage dashboard (usage stats)
    case wallpaperSwap              // the desktop wallpaper crossfades to a fresh photo (bing daily)
    case textTransform(TextTransformSample) // selected text transforms in place (case change / strip formatting)

    /// POC mapping. Will become metadata-driven (manifest `archetype` + sample,
    /// or derived from which adapter primitives the feature uses).
    static func of(_ feature: FeatureInfo) -> FeatureArchetype {
        switch feature.id {
        case "window_switcher":   return .chooser(.windows)
        case "clipboard_history": return .chooser(.clipboard)
        case "command_palette":   return .chooser(.commands)
        case "tab_switcher":      return .chooser(.tabs)
        case "site_switcher":     return .chooser(.sites)
        case "locate_pointer":    return .pointerPulse
        case "pointer_follows_window": return .pointerFollow
        case "password_generator": return .passwordReveal
        case "window_snap":       return .windowArrange(.snap)
        case "window_modal":      return .windowArrange(.windowMode)
        case "break_reminder":    return .banner(.breakReminder)
        case "sleep_schedule":    return .screenOff(.sleep)
        case "display_off":       return .screenOff(.displayOff)
        case "count_down":        return .countdownStrip
        case "usage_stats":       return .chart
        case "bing_daily":        return .wallpaperSwap
        case "text_actions":      return .textTransform(.caseChange)
        case "plain_paste":       return .textTransform(.stripFormat)
        default:                  return .none
        }
    }

    /// Seconds for one visible loop of this archetype's scene. MUST equal the
    /// scene's heartbeat interval x its cycle length -- the gallery's playback
    /// progress bar is anchored at hover-start and sweeps over this duration, so
    /// it hits 100% exactly when the scene restarts its loop. Keep in sync if a
    /// scene's `.heartbeat(...)` interval or cycle changes.
    var loopDuration: Double {
        switch self {
        case .none:                 return 0
        case .chooser(let s):       return 0.85 * Double(max(1, s.rows.count))   // step per row
        case .windowArrange(let s): return 0.95 * Double(max(1, s.moves.count))  // step per move
        case .banner:               return 1.3 * 2     // slide in + out
        case .screenOff:            return 1.4 * 2     // dark + lit
        case .countdownStrip:       return 0.55 * 5    // cycle = 5 states
        case .pointerPulse:         return 0.4 * 6     // cycle = 6
        case .pointerFollow:        return 1.1 * 2     // two spots
        case .passwordReveal:       return 0.32 * 6    // cycle = 6
        case .chart:                return 1.6 * 2     // grow + reset
        case .wallpaperSwap:        return 1.9 * 2     // two wallpapers
        case .textTransform:        return 1.5 * 2     // before + after
        }
    }

    @MainActor @ViewBuilder
    func scene(playing: Bool) -> some View {
        switch self {
        case .none:                       EmptyView()
        case .chooser(let sample):        ChooserArchetypeScene(sample: sample, playing: playing)
        case .windowArrange(let sample):  WindowArrangeArchetypeScene(sample: sample, playing: playing)
        case .banner(let sample):         BannerArchetypeScene(sample: sample, playing: playing)
        case .screenOff(let sample): ScreenOffArchetypeScene(sample: sample, playing: playing)
        case .countdownStrip:        CountdownStripArchetypeScene(playing: playing)
        case .pointerPulse:          PointerPulseArchetypeScene(playing: playing)
        case .pointerFollow:         PointerFollowArchetypeScene(playing: playing)
        case .passwordReveal:        PasswordRevealArchetypeScene(playing: playing)
        case .chart:                 UsageChartArchetypeScene(playing: playing)
        case .wallpaperSwap:         WallpaperSwapArchetypeScene(playing: playing)
        case .textTransform(let s):  TextTransformArchetypeScene(sample: s, playing: playing)
        }
    }
}

// MARK: - Per-action preview (the trigger editor)

extension FeatureArchetype {
    /// Whether the (feature, action) pair is worth a preview frame in the trigger
    /// editor: an action-specific window move, or any feature with a non-`.none`
    /// archetype (which falls back to the feature-level loop).
    static func hasActionPreview(feature: FeatureInfo, actionId: String) -> Bool {
        if windowActionSample(feature: feature, actionId: actionId) != nil { return true }
        if case .none = of(feature) { return false }
        return true
    }

    /// A preview specialized to ONE action when it maps to a distinct window move
    /// (window_snap's direction/maximize/throw actions); otherwise the feature's
    /// usual gallery loop. Lets the editor show "what THIS shortcut does".
    @MainActor @ViewBuilder
    static func actionScene(feature: FeatureInfo, actionId: String, playing: Bool) -> some View {
        if let sample = windowActionSample(feature: feature, actionId: actionId) {
            WindowArrangeArchetypeScene(sample: sample, playing: playing)
        } else {
            of(feature).scene(playing: playing)
        }
    }

    /// window_snap's per-action sample: the window RESTS in the action's end
    /// state (so the still frame already shows where it lands) and, while
    /// playing, pulses to a neutral box and back so the move reads. Returns nil
    /// for anything without a distinct window-rect end state (caller falls back).
    private static func windowActionSample(feature: FeatureInfo,
                                           actionId: String) -> WindowArrangeSample? {
        guard feature.id == "window_snap" else { return nil }
        let neutral = CGRect(x: 0.28, y: 0.28, width: 0.44, height: 0.44)
        func onScreen(_ target: CGRect) -> WindowArrangeSample {
            WindowArrangeSample(moves: [WindowArrangeMove(target), WindowArrangeMove(neutral)],
                                screenCount: 1, legend: nil)
        }
        switch actionId {
        case "left":       return onScreen(CGRect(x: 0,   y: 0,   width: 0.5, height: 1))
        case "right":      return onScreen(CGRect(x: 0.5, y: 0,   width: 0.5, height: 1))
        case "top":        return onScreen(CGRect(x: 0,   y: 0,   width: 1,   height: 0.5))
        case "bottom":     return onScreen(CGRect(x: 0,   y: 0.5, width: 1,   height: 0.5))
        case "toggle_max": return onScreen(CGRect(x: 0,   y: 0,   width: 1,   height: 1))
        case "screen_next":
            return WindowArrangeSample(
                moves: [WindowArrangeMove(neutral, 1), WindowArrangeMove(neutral, 0)],
                screenCount: 2, legend: nil)
        case "screen_prev":
            return WindowArrangeSample(
                moves: [WindowArrangeMove(neutral, 0), WindowArrangeMove(neutral, 1)],
                screenCount: 2, legend: nil)
        default:           return nil
        }
    }
}

// MARK: - Hover-gated heartbeat

/// A periodic tick that runs ONLY while `active` (card hover). The gallery shows
/// ~17 archetype cards at once; a free-running `Timer.publish` per card would
/// wake the main thread continuously even for paused (un-hovered) scenes. This
/// starts the timer on hover and tears it down on exit -- or when the card
/// scrolls off (`onDisappear`) -- so an idle gallery does zero animation work.
private struct Heartbeat: ViewModifier {
    let interval: TimeInterval
    let active: Bool
    let onTick: () -> Void

    @State private var cancellable: AnyCancellable?

    func body(content: Content) -> some View {
        content
            .onAppear { if active { start() } }
            .onDisappear { stop() }
            .onChange(of: active) { isOn in
                if isOn { start() } else { stop() }
            }
    }

    private func start() {
        stop()   // never stack two timers
        cancellable = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in onTick() }
    }

    private func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}

private extension View {
    /// Tick `onTick` every `interval` seconds, but only while `active` is true.
    func heartbeat(_ interval: TimeInterval, active: Bool, onTick: @escaping () -> Void) -> some View {
        modifier(Heartbeat(interval: interval, active: active, onTick: onTick))
    }
}

// MARK: - Chooser / palette archetype

/// One sample row in a chooser: a faux glyph, a bold primary label, and a
/// secondary detail. For window_switcher that's app + window title (two rows can
/// share an app -- the point vs the macOS switcher); for clipboard_history it's
/// the entry kind + the copied text.
struct ChooserRow {
    let glyph: String   // SF Symbol standing in for the per-row icon
    let primary: String
    let secondary: String
}

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
}

/// A stylized chooser panel: it pops in, a selection highlight steps down the
/// result rows (arrow-key navigation), the chosen row flashes (enter), and it
/// loops. Plays only while `playing` (hover); at rest it shows a calm first
/// frame so the grid isn't 20 things moving at once.
private struct ChooserArchetypeScene: View {
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

// MARK: - Window-arrange archetype (snap AND modal -- they share the effect)

/// One step in a window-arrange sequence: a normalized target rect plus the
/// display it lives on (0-based). Single-display samples leave `screen` at 0.
struct WindowArrangeMove {
    let rect: CGRect       // normalized within ITS display (origin top-left)
    let screen: Int        // which display (0-based); 0 for single-screen samples
    init(_ rect: CGRect, _ screen: Int = 0) { self.rect = rect; self.screen = screen }
}

/// The per-feature content the window-arrange scene plays: a sequence of moves
/// the window springs through, the display count to render, and an optional mode
/// legend. window_snap shows half/maximize snaps and a cross-screen throw across
/// two displays; window_modal shows a richer single-display sequence (snap +
/// center + resize + maximize + quarter) plus a "mode" chip -- same effect
/// family, different repertoire, so they share one scene.
struct WindowArrangeSample {
    let moves: [WindowArrangeMove]
    let screenCount: Int   // displays the scene renders side by side (1 or 2)
    let legend: String?    // non-nil => render a modal-mode chip (window_modal)

    /// window_snap: direct-hotkey halves + maximize, then THROW to the 2nd
    /// display (window_snap's marquee move -- the only sample that needs two
    /// screens). No quarter: window_snap has no quarter action (that's modal).
    static let snap = WindowArrangeSample(
        moves: [
            WindowArrangeMove(CGRect(x: 0,   y: 0, width: 0.5, height: 1)),       // left half
            WindowArrangeMove(CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),       // right half
            WindowArrangeMove(CGRect(x: 0,   y: 0, width: 1,   height: 1)),       // maximize
            WindowArrangeMove(CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7), 1), // throw to screen 2
        ],
        screenCount: 2,
        legend: nil)

    /// window_modal: the superset -- snap, then center, expand, maximize, quarter.
    /// Single display: its sample doesn't include a cross-screen move, and the
    /// legend chip is what distinguishes it. The legend (with key hints) marks
    /// the modal ENTRY and stays while the mode is active, mirroring the real
    /// feature's persistent legend banner.
    static let windowMode = WindowArrangeSample(
        moves: [
            WindowArrangeMove(CGRect(x: 0,    y: 0,   width: 0.5,  height: 1)),    // snap left
            WindowArrangeMove(CGRect(x: 0.27, y: 0.2, width: 0.46, height: 0.6)),  // center (floating)
            WindowArrangeMove(CGRect(x: 0.12, y: 0.1, width: 0.76, height: 0.8)),  // expand a step
            WindowArrangeMove(CGRect(x: 0,    y: 0,   width: 1,    height: 1)),    // maximize
            WindowArrangeMove(CGRect(x: 0.5,  y: 0,   width: 0.5,  height: 0.5)),  // top-right quarter
        ],
        screenCount: 1,
        legend: "Window Mode · H J K L · esc")
}

/// A stylized desktop -- one or two displays side by side -- with a single
/// window that springs through the sample's move sequence, looping. Shared by
/// window_snap (two displays; the last move THROWS the window to the 2nd) and
/// window_modal (single display). Plays only while `playing` (hover); at rest it
/// shows the first move (the calm frame). window_modal also shows a "mode" chip.
private struct WindowArrangeArchetypeScene: View {
    let sample: WindowArrangeSample
    let playing: Bool

    @State private var step = 0

    private var move: WindowArrangeMove { sample.moves[step % sample.moves.count] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let gap: CGFloat = 3          // window inset within its display
            let screenGap: CGFloat = 6    // gap between the two displays
            let n = max(1, sample.screenCount)
            let dispW = (w - screenGap * CGFloat(n - 1)) / CGFloat(n)
            let r = move.rect
            let s = min(max(move.screen, 0), n - 1)
            let dispX = CGFloat(s) * (dispW + screenGap)
            ZStack(alignment: .topLeading) {
                // the desktop(s)
                ForEach(0..<n, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.secondary.opacity(0.10), .secondary.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
                        .frame(width: dispW, height: h)
                        .offset(x: CGFloat(i) * (dispW + screenGap), y: 0)
                }

                // the window that arranges (hops between displays on a throw)
                window
                    .frame(width: max(0, r.width * dispW - gap * 2),
                           height: max(0, r.height * h - gap * 2))
                    .offset(x: dispX + r.minX * dispW + gap, y: r.minY * h + gap)
                    .animation(.spring(response: 0.4, dampingFraction: 0.72), value: step)

                // modal indicator: the legend chip is PERSISTENT -- it marks the
                // feature as a modal keyboard layer (the thing that distinguishes
                // window_modal from window_snap), so it stays visible at rest too.
                if let legend = sample.legend {
                    modeChip(legend)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 5)
                        .opacity(playing ? 1 : 0.9)
                }
            }
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(0.95, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to the first move (calm frame) at rest
        }
    }

    private func modeChip(_ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "command").font(.system(size: 7, weight: .bold))
            Text(text).font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.9)))
    }

    private var window: some View {
        VStack(spacing: 0) {
            // title bar with traffic-light dots
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(Color.accentColor.opacity(0.28))
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Banner / modal archetype

/// The per-feature content a banner scene renders: an icon, a title, and a
/// short subtitle/legend. Like the chooser, the motion is shared and only this
/// differs between banner features.
struct BannerSample {
    let glyph: String
    let title: String
    let subtitle: String

    static let breakReminder = BannerSample(
        glyph: "eyes", title: "Time for a break", subtitle: "Rest your eyes for a moment")
}

/// A notification/legend pill that slides in from the top edge, holds, slides
/// back out, and loops -- the signature "a banner appears" motion. Plays only
/// while `playing` (hover); at rest it rests fully shown (the calm frame).
private struct BannerArchetypeScene: View {
    let sample: BannerSample
    let playing: Bool

    @State private var shown = true   // calm frame = banner resting in view

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // a faint desktop backdrop so the slide reads against an edge
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))

                banner
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    // slide up out of frame (above the top edge) when hidden
                    .offset(y: shown ? 0 : -(geo.size.height))
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: shown)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heartbeat(1.3, active: playing) { shown.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { shown = true }   // settle back to the shown calm frame
        }
    }

    private var banner: some View {
        HStack(spacing: 7) {
            Image(systemName: sample.glyph)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(sample.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(sample.subtitle)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Screen-off effect (system sleep / display off)

/// The per-feature face of the screen-off effect: the glyph + label shown once
/// the screen has gone dark (a moon for sleep, a power icon for display-off).
struct ScreenOffSample {
    let glyph: String
    let label: String

    static let sleep      = ScreenOffSample(glyph: "moon.fill",  label: "Asleep")
    static let displayOff = ScreenOffSample(glyph: "powersleep", label: "Display off")
}

/// Previews the EFFECT: a lit desktop fades to black, the feature's glyph + label
/// surface on the dark screen, then it wakes -- looping. Plays only while
/// `playing` (hover); at rest it shows the lit desktop (the calm frame).
private struct ScreenOffArchetypeScene: View {
    let sample: ScreenOffSample
    let playing: Bool

    @State private var dark = false

    var body: some View {
        ZStack {
            // a lit desktop: subtle wallpaper + a menubar strip + a window
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18), .secondary.opacity(0.06)],
                                     startPoint: .top, endPoint: .bottom))
            VStack(spacing: 0) {
                Rectangle().fill(.secondary.opacity(0.18)).frame(height: 7)
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(.background.opacity(0.7))
                .frame(width: 46, height: 26)

            // the screen-off overlay
            RoundedRectangle(cornerRadius: 6)
                .fill(.black)
                .opacity(dark ? 0.92 : 0)
            VStack(spacing: 3) {
                Image(systemName: sample.glyph)
                    .font(.system(size: 15, weight: .medium))
                Text(sample.label).font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .opacity(dark ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.55), value: dark)
        .heartbeat(1.4, active: playing) { dark.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { dark = false }   // settle back to the lit calm frame
        }
    }
}

// MARK: - Countdown progress-strip effect

/// Previews count_down's actual effect: a thin progress strip runs along the top
/// edge of the screen and depletes to nothing, then repeats. Plays only while
/// `playing` (hover); at rest it shows the full strip (the calm frame).
private struct CountdownStripArchetypeScene: View {
    let playing: Bool

    private let cycle = 5   // states 0..4; remaining = (cycle-1-state)/(cycle-1)
    @State private var step = 0

    private var remaining: Double {
        let state = step % cycle
        return Double(cycle - 1 - state) / Double(cycle - 1)   // 1 -> 0
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // the desktop
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                // the thin progress strip along the top edge
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (playing ? remaining : 1) * (w - 12)), height: 4)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .animation(.linear(duration: 0.5), value: step)

                // remaining-time label, centered
                Text(playing ? "\(Int((remaining * 3).rounded(.up)))m" : "3m")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heartbeat(0.55, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to the full-strip calm frame
        }
    }
}

// MARK: - Pointer-pulse effect (locate pointer)

/// Previews locate_pointer's effect: a crosshair snaps onto the cursor and
/// concentric rings pulse outward and fade -- the "where's my mouse" flash.
/// Pure motion, no per-feature content. Plays only while `playing` (hover); at
/// rest it shows just the cursor on a calm desktop.
private struct PointerPulseArchetypeScene: View {
    let playing: Bool

    private let cycle = 6
    @State private var step = 0

    /// 0 -> ~0.83 sawtooth; the ring grows as phase rises and fades as it nears 1,
    /// so the jump back to 0 happens while it's invisible (same trick as the strip).
    private var phase: Double { Double(step % cycle) / Double(cycle) }

    var body: some View {
        GeometryReader { geo in
            // cursor sits a touch right-of-center, like a real desktop pointer
            let cx = geo.size.width * 0.55
            let cy = geo.size.height * 0.5
            let maxR = min(geo.size.width, geo.size.height) * 0.6
            ZStack(alignment: .topLeading) {
                // calm desktop backdrop
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                if playing {
                    // crosshair lines through the cursor
                    Rectangle().fill(Color.accentColor.opacity(0.4))
                        .frame(width: geo.size.width, height: 1)
                        .position(x: geo.size.width / 2, y: cy)
                    Rectangle().fill(Color.accentColor.opacity(0.4))
                        .frame(width: 1, height: geo.size.height)
                        .position(x: cx, y: geo.size.height / 2)

                    // two rings, offset in phase, expanding + fading from the cursor
                    ring(phase, cx: cx, cy: cy, maxR: maxR)
                    ring((phase + 0.5).truncatingRemainder(dividingBy: 1), cx: cx, cy: cy, maxR: maxR)
                }

                // the cursor itself (always present -- the calm frame)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .position(x: cx, y: cy)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.linear(duration: 0.38), value: step)
        }
        .heartbeat(0.4, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to just-the-cursor calm frame
        }
    }

    private func ring(_ p: Double, cx: CGFloat, cy: CGFloat, maxR: CGFloat) -> some View {
        let d = (0.2 + p * 1.0) * maxR     // diameter grows with phase
        return Circle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: d, height: d)
            .position(x: cx, y: cy)
            .opacity(1 - p)                // fade as it expands
    }
}

// MARK: - Pointer-follows-window effect

/// Previews pointer_follows_window: when a window jumps to a new spot, the cursor
/// chases after it and lands on the new position. The cursor uses a slower spring
/// than the window, so it visibly LAGS behind -- that trailing motion is the whole
/// point. Pure motion. Plays only while `playing` (hover); at rest both sit still.
private struct PointerFollowArchetypeScene: View {
    let playing: Bool

    // two spots the window toggles between; the cursor follows to each.
    private let moves = [
        CGRect(x: 0.05, y: 0.14, width: 0.42, height: 0.66),
        CGRect(x: 0.53, y: 0.20, width: 0.42, height: 0.66),
    ]
    @State private var step = 0

    private var target: CGRect { moves[step % moves.count] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let gap: CGFloat = 3
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.secondary.opacity(0.10), .secondary.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                // the window that moves
                window
                    .frame(width: max(0, target.width * w - gap * 2),
                           height: max(0, target.height * h - gap * 2))
                    .offset(x: target.minX * w + gap, y: target.minY * h + gap)
                    .animation(.spring(response: 0.38, dampingFraction: 0.74), value: step)

                // the cursor lands near the window's title bar, with a SLOWER spring
                // so it trails the window into place.
                Image(systemName: "cursorarrow")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .position(x: (target.minX + target.width * 0.5) * w,
                              y: (target.minY + 0.18) * h)
                    .animation(.spring(response: 0.62, dampingFraction: 0.7), value: step)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(1.1, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to the first spot (calm frame)
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(Color.accentColor.opacity(0.28))
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Password-reveal effect (password generator)

/// Previews password_generator's effect: characters scramble, lock into a strong
/// password, the strength meter fills, then a "Copied" check flashes (it copies
/// to the clipboard). Pure motion. Plays only while `playing` (hover); at rest it
/// shows the settled password (the calm frame).
private struct PasswordRevealArchetypeScene: View {
    let playing: Bool

    // The last frame is the locked password; earlier frames are scramble noise of
    // the same length so the field doesn't jump width.
    private let frames = ["q2$xZ9wK", "7Kp#4mR8", "v8!Lr3nP", "Hk7$mP9w"]
    private let cycle = 6     // 0..2 scramble, 3 locked, 4 copied, 5 hold
    @State private var step = 0

    private var state: Int { step % cycle }
    private var locked: Bool { state >= 3 }
    private var copied: Bool { state == 4 || state == 5 }
    private var shownText: String {
        guard playing else { return frames.last! }
        return locked ? frames.last! : frames[state % (frames.count - 1)]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

            VStack(spacing: 6) {
                // the password field
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(locked ? Color.accentColor : .secondary)
                    Text(shownText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(locked ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if copied {
                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Copied").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke((locked ? Color.accentColor : .secondary).opacity(0.4), lineWidth: 1))

                // strength meter: fills as the password locks in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(locked ? Color.green : Color.secondary.opacity(0.25))
                            .frame(height: 3)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)
        .heartbeat(0.32, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to the locked-password calm frame
        }
    }
}

// MARK: - Usage-chart effect (usage stats)

/// Previews usage_stats: a little "today" dashboard whose per-app focus-time bars
/// grow in -- so the card says "see where your time goes" at a glance, not just
/// "tracks usage". Pure motion with fixed sample apps. Plays only while `playing`
/// (hover); at rest the bars rest filled (the calm frame).
private struct UsageChartArchetypeScene: View {
    let playing: Bool

    private struct Bar { let glyph: String; let label: String; let value: Double; let time: String }
    private let bars = [
        Bar(glyph: "chevron.left.forwardslash.chevron.right", label: "Code",   value: 1.0,  time: "2h"),
        Bar(glyph: "globe",                                   label: "Chrome", value: 0.62, time: "1h"),
        Bar(glyph: "message",                                 label: "Slack",  value: 0.34, time: "40m"),
    ]

    @State private var grown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Today").font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
                Text("3h 40m").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            ForEach(0..<bars.count, id: \.self) { i in barRow(bars[i]) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.18), lineWidth: 1))
        .heartbeat(1.6, active: playing) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { grown.toggle() }
        }
        .onChange(of: playing) { isOn in
            if !isOn { grown = true }   // bars rest filled
        }
    }

    private func barRow(_ bar: Bar) -> some View {
        HStack(spacing: 5) {
            Image(systemName: bar.glyph)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(bar.label).font(.system(size: 8)).frame(width: 36, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.15)).frame(height: 6)
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(height: 6)
                    .scaleEffect(x: grown ? bar.value : 0.03, anchor: .leading)
            }
            Text(bar.time).font(.system(size: 7)).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
        }
    }
}

// MARK: - Wallpaper-swap effect (bing daily)

/// Previews bing_daily: the desktop wallpaper crossfades from one photo to a
/// fresh one -- so the card reads "new wallpaper every day," not just "appearance
/// feature." The photos are stylized landscapes (sky gradient + sun + ridge).
/// Pure motion. Plays only while `playing` (hover); at rest it shows the first.
private struct WallpaperSwapArchetypeScene: View {
    let playing: Bool

    @State private var second = false

    var body: some View {
        ZStack(alignment: .top) {
            landscape(sky: [Color(red: 0.99, green: 0.74, blue: 0.42), Color(red: 0.96, green: 0.45, blue: 0.45)],
                      sun: Color(red: 1, green: 0.93, blue: 0.7), ridge: Color(red: 0.55, green: 0.27, blue: 0.35))
            landscape(sky: [Color(red: 0.45, green: 0.69, blue: 0.98), Color(red: 0.28, green: 0.45, blue: 0.78)],
                      sun: Color(red: 0.92, green: 0.97, blue: 1), ridge: Color(red: 0.2, green: 0.32, blue: 0.5))
                .opacity(second ? 1 : 0)

            // menubar strip so it reads as a real desktop
            Rectangle().fill(.black.opacity(0.18)).frame(height: 7)

            // "daily photo" badge, bottom-trailing
            HStack(spacing: 3) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 7, weight: .bold))
                Text("Daily").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.35)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
        .animation(.easeInOut(duration: 0.7), value: second)
        .heartbeat(1.9, active: playing) { second.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { second = false }   // settle to the first wallpaper
        }
    }

    private func landscape(sky: [Color], sun: Color, ridge: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
                // sun
                Circle().fill(sun)
                    .frame(width: h * 0.28, height: h * 0.28)
                    .position(x: w * 0.74, y: h * 0.34)
                // a ridge of hills along the bottom
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.84))
                    p.addLine(to: CGPoint(x: w * 0.6, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w, y: h * 0.82))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.closeSubpath()
                }
                .fill(ridge)
            }
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
private struct TextTransformArchetypeScene: View {
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
