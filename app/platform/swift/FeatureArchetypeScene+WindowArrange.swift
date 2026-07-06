import SwiftUI

// Window-arrange archetype (snap AND modal -- they share the effect). One of the
// FeatureArchetype scenes; the core enum + dispatch live in
// FeatureArchetypeAnimation.swift.

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
struct WindowArrangeArchetypeScene: View {
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

/// window_snap's "swap windows between displays": TWO displays, each holding its
/// own window; every beat the two windows EXCHANGE displays (and back). Distinct
/// from the single-window throw -- two windows crossing reads as a swap, not a move.
/// A dedicated scene because WindowArrangeArchetypeScene animates only one window.
struct WindowSwapArchetypeScene: View {
    let playing: Bool
    @State private var swapped = false

    // Each window sits inset within its display; the two are tinted differently so
    // the exchange is legible as they cross.
    private let inset = CGRect(x: 0.12, y: 0.15, width: 0.76, height: 0.7)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let screenGap: CGFloat = 6
            let dispW = (w - screenGap) / 2
            let gap: CGFloat = 3
            let aDisplay = swapped ? 1 : 0
            let bDisplay = swapped ? 0 : 1
            let ax = CGFloat(aDisplay) * (dispW + screenGap) + inset.minX * dispW + gap
            let bx = CGFloat(bDisplay) * (dispW + screenGap) + inset.minX * dispW + gap
            ZStack(alignment: .topLeading) {
                ForEach(0..<2, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.secondary.opacity(0.10), .secondary.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))
                        .frame(width: dispW, height: h)
                        .offset(x: CGFloat(i) * (dispW + screenGap), y: 0)
                }
                swapWindow(.accentColor)
                    .frame(width: max(0, inset.width * dispW - gap * 2), height: max(0, inset.height * h - gap * 2))
                    .offset(x: ax, y: inset.minY * h + gap)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: swapped)
                swapWindow(.orange)
                    .frame(width: max(0, inset.width * dispW - gap * 2), height: max(0, inset.height * h - gap * 2))
                    .offset(x: bx, y: inset.minY * h + gap)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: swapped)
            }
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(0.95, active: playing) { swapped.toggle() }
        .onChange(of: playing) { isOn in if !isOn { swapped = false } }
    }

    private func swapWindow(_ tint: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.secondary.opacity(0.5)).frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).frame(height: 9)
            .background(tint.opacity(0.28))
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
