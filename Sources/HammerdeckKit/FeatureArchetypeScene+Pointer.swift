import SwiftUI

// Pointer / cursor archetype scenes -- locate-pointer pulse, pointer-follows-
// window trail, and the center-on-window action. Part of the FeatureArchetype
// scene set; the core enum + dispatch live in FeatureArchetypeAnimation.swift.

// MARK: - Pointer-pulse effect (locate pointer)

/// Previews locate_pointer's effect: a crosshair snaps onto the cursor and
/// concentric rings pulse outward and fade -- the "where's my mouse" flash.
/// Pure motion, no per-feature content. Plays only while `playing` (hover); at
/// rest it shows just the cursor on a calm desktop.
struct PointerPulseArchetypeScene: View {
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
struct PointerFollowArchetypeScene: View {
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

// MARK: - Center-pointer-on-window effect (Pointer feature, "center" action)

/// Previews the Pointer feature's "Center pointer on focused window" action: a
/// window sits in the frame and the cursor springs from an off-corner to its
/// exact center, where a locate ring flashes (the action ends in locateMouse).
/// At rest the cursor sits centered on the window (the end state -- the calm
/// frame shows where it lands). Plays only while `playing` (hover).
struct PointerCenterArchetypeScene: View {
    let playing: Bool

    // The window the pointer centers on, and the off-corner it starts from.
    private let win = CGRect(x: 0.24, y: 0.20, width: 0.52, height: 0.58)
    private let corner = CGPoint(x: 0.10, y: 0.14)

    @State private var step = 0

    // At rest, show the centered end state; while playing, toggle corner<->center.
    private var centered: Bool { playing ? (step % 2 == 1) : true }
    private var center: CGPoint { CGPoint(x: win.midX, y: win.midY) }
    private var spot: CGPoint { centered ? center : corner }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cx = spot.x * w, cy = spot.y * h
            let ringD = min(w, h) * 0.42
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                // the target window
                window
                    .frame(width: win.width * w, height: win.height * h)
                    .offset(x: win.minX * w, y: win.minY * h)

                // locate ring flashing at the window center once the cursor lands
                if playing && centered {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: ringD, height: ringD)
                        .position(x: center.x * w, y: center.y * h)
                        .opacity(0.0)
                        .modifier(RingPulse())
                }

                Image(systemName: "cursorarrow")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .position(x: cx, y: cy)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: step)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heartbeat(0.95, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to the centered calm frame
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

/// One expand-and-fade pulse, driven on appearance -- the ring is re-created each
/// time the cursor lands centered, so a plain onAppear animation gives the flash.
private struct RingPulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.0 : 0.4)
            .opacity(on ? 0.0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.7)) { on = true }
            }
    }
}
