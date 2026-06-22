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
// This file is the DISPATCHER: the `FeatureArchetype` enum (id -> archetype, loop
// duration, scene), the per-action preview entry points, and the shared
// hover-gated `heartbeat`. Each scene lives in its own `FeatureArchetypeScene+*`
// file (Chooser, WindowArrange, Pointer, Banner, ScreenEffects, StatusCards,
// Text, OptionPreview) -- same split-by-domain shape as `Native+*.swift`.

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
        case "text_actions":      return .chooser(.textActions)
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
        if feature.id == "locate_pointer", actionId == "center" {
            // The Pointer feature's two actions need DIFFERENT previews: "Locate
            // pointer" is the crosshair pulse (the feature archetype), but
            // "Center pointer on focused window" is the cursor jumping into a
            // window's center -- its own scene.
            PointerCenterArchetypeScene(playing: playing)
        } else if feature.id == "plain_paste", actionId == "type" {
            // plain_paste's two actions diverge: "Paste as plain text" is the
            // strip-format effect (the feature archetype), but "Type clipboard
            // as keystrokes" types the clipboard out char-by-char -- a typing
            // scene, nothing to do with stripping styling.
            TypeKeystrokesArchetypeScene(playing: playing)
        } else if let sample = windowActionSample(feature: feature, actionId: actionId) {
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

// MARK: - Hover-gated heartbeat (shared by every scene)

/// A periodic tick that runs ONLY while `active` (card hover). The gallery shows
/// ~17 archetype cards at once; a free-running `Timer.publish` per card would
/// wake the main thread continuously even for paused (un-hovered) scenes. This
/// starts the timer on hover and tears it down on exit -- or when the card
/// scrolls off (`onDisappear`) -- so an idle gallery does zero animation work.
struct Heartbeat: ViewModifier {
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

extension View {
    /// Tick `onTick` every `interval` seconds, but only while `active` is true.
    func heartbeat(_ interval: TimeInterval, active: Bool, onTick: @escaping () -> Void) -> some View {
        modifier(Heartbeat(interval: interval, active: active, onTick: onTick))
    }
}
