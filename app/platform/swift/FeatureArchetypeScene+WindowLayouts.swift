import SwiftUI

// Window-LAYOUT archetypes: the focused window landing in a GRID CELL
// (window_grid), a screen's windows tiling with one lifted to a centered HERO
// (window_deck), and scattered windows gathering into the diamond-ring STACK
// (window_stack). Distinct from FeatureArchetypeScene+WindowArrange, which
// springs ONE window's rect through snap/modal states -- these show a MULTI-
// WINDOW layout (a numbered grid; a deck of tiles; a ringed pile), so they earn
// their own scene. Core enum + dispatch live in FeatureArchetypeAnimation.swift.

/// window_grid: a desktop under a visible 3x3 numbered grid; the focused window
/// (accent) hops from cell to cell, landing squarely in each -- the feature's
/// "a hotkey deems the screen an N×N grid, a number key drops the window in that
/// cell" flow, numbers in reading order. Plays only while `playing` (hover); at
/// rest it shows the window resting in the first visited cell (the calm frame).
struct WindowGridArchetypeScene: View {
    let playing: Bool

    // The tick interval and the cells the window hops through, in reading-order
    // index (0 = top-left): four corners + center, so the hop is lively and every
    // quadrant reads. These are the SOLE source of `loopDuration` below, which
    // FeatureArchetype returns verbatim -- so the gallery's playback bar cannot
    // drift from the scene when the hop is retuned (add a cell and both update).
    // nonisolated so FeatureArchetype.loopDuration (nonisolated) can read them;
    // a SwiftUI View type is inferred @MainActor, which would otherwise wall them off.
    nonisolated static let heartbeat = 0.7
    nonisolated static let cellOrder = [0, 2, 8, 6, 4]
    /// One visible loop = one tick per visited cell.
    nonisolated static let loopDuration = heartbeat * Double(cellOrder.count)

    private let cols = 3, rows = 3

    @State private var step = 0

    private var cell: Int { Self.cellOrder[step % Self.cellOrder.count] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let gap: CGFloat = 3
            let cellW = w / CGFloat(cols), cellH = h / CGFloat(rows)
            let col = cell % cols, row = cell / cols
            ZStack(alignment: .topLeading) {
                // desktop
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.secondary.opacity(0.10), .secondary.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.18), lineWidth: 1))

                // the numbered cheat-sheet the feature shows -- one digit per cell,
                // reading order, faint so the landed window reads on top.
                ForEach(0..<(cols * rows), id: \.self) { i in
                    Text("\(i + 1)")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .frame(width: cellW, height: cellH)
                        .offset(x: CGFloat(i % cols) * cellW, y: CGFloat(i / cols) * cellH)
                }

                // faint grid guides
                Path { p in
                    for c in 1..<cols {
                        p.move(to: CGPoint(x: CGFloat(c) * cellW, y: 0))
                        p.addLine(to: CGPoint(x: CGFloat(c) * cellW, y: h))
                    }
                    for r in 1..<rows {
                        p.move(to: CGPoint(x: 0, y: CGFloat(r) * cellH))
                        p.addLine(to: CGPoint(x: w, y: CGFloat(r) * cellH))
                    }
                }
                .stroke(.secondary.opacity(0.16), lineWidth: 0.5)

                // the focused window, landing in the active cell
                window
                    .frame(width: max(0, cellW - gap * 2), height: max(0, cellH - gap * 2))
                    .offset(x: CGFloat(col) * cellW + gap, y: CGFloat(row) * cellH + gap)
                    .animation(.spring(response: 0.4, dampingFraction: 0.72), value: step)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(Self.heartbeat, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // reset to the first cell (calm frame) at rest
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.7)).frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(Color.accentColor.opacity(0.9))
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.85), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// window_deck: a screen's windows laid out as a uniform grid; focus one and it
/// lifts to a large centered HERO with the others peeking behind in their slots.
/// The promoted tile FLIES from its slot to the center (and the previous hero
/// steps home), cycling among a few tiles -- focus IS the promotion signal in the
/// real feature. Plays only while `playing` (hover); at rest it shows the first
/// tile promoted (the calm frame).
struct WindowDeckArchetypeScene: View {
    let playing: Bool

    // The tick interval and which tile is the hero, in order (a spread so the fly
    // path reads each time). SOLE source of `loopDuration`, as in the grid scene,
    // so the playback bar tracks the cycle even if the hero list is retuned.
    // nonisolated for the same reason as the grid scene: read by the nonisolated
    // FeatureArchetype.loopDuration.
    nonisolated static let heartbeat = 1.3
    nonisolated static let heroOrder = [0, 4, 2]
    /// One visible loop = one tick per promoted hero.
    nonisolated static let loopDuration = heartbeat * Double(heroOrder.count)

    private let cols = 3, rows = 2       // a 6-window deck
    private var count: Int { cols * rows }

    @State private var step = 0

    private var heroIndex: Int { Self.heroOrder[step % Self.heroOrder.count] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let gap: CGFloat = 4
            let cellW = w / CGFloat(cols), cellH = h / CGFloat(rows)
            let heroW = w * 0.6, heroH = h * 0.68
            let heroX = (w - heroW) / 2, heroY = (h - heroH) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.06))

                // Every window keeps a STABLE identity across steps, so when the
                // hero changes SwiftUI animates each tile's frame -- the new hero
                // flies slot -> center while the old one steps home. The hero rides
                // on top (zIndex) and casts a shadow so it reads as lifted.
                ForEach(0..<count, id: \.self) { i in
                    let isHero = i == heroIndex
                    let c = i % cols, r = i / cols
                    tile(active: isHero)
                        .frame(width: isHero ? heroW : max(0, cellW - gap * 2),
                               height: isHero ? heroH : max(0, cellH - gap * 2))
                        .offset(x: isHero ? heroX : CGFloat(c) * cellW + gap,
                                y: isHero ? heroY : CGFloat(r) * cellH + gap)
                        .zIndex(isHero ? 1 : 0)
                        .shadow(color: .black.opacity(isHero ? 0.22 : 0), radius: 6, y: 3)
                        .animation(.spring(response: 0.46, dampingFraction: 0.76), value: step)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(Self.heartbeat, active: playing) { step += 1 }
        .onChange(of: playing) { isOn in
            if !isOn { step = 0 }   // settle to the first hero (calm frame) at rest
        }
    }

    private func tile(active: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(active ? Color.white.opacity(0.75) : .secondary.opacity(0.5))
                        .frame(width: 3, height: 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 9)
            .background(active ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.28))
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// window_stack: a screen's scattered windows FAN out against the screen edges
/// (platform.windows.fanSlots) -- each becomes a slab flush against its own
/// segment of an edge, so every window keeps a full colored EDGE STRIP that no
/// other window can cover, in its own slice of the border. The focused window
/// sits on top. Alternates scattered <-> fanned; at rest it shows the fan (the
/// calm frame). Positions mirror the real round-robin T,B,L,R assignment.
struct WindowStackArchetypeScene: View {
    let playing: Bool

    // SOLE source of `loopDuration`, as in the grid/deck scenes. nonisolated for
    // the same reason: read by the nonisolated FeatureArchetype.loopDuration.
    nonisolated static let heartbeat = 1.6
    /// One visible loop = scattered + fanned.
    nonisolated static let loopDuration = heartbeat * 2

    @State private var fanned = true

    private enum Side { case top, bottom, left, right }

    // Feature palette head (deck colors). Round-robin T,B,L,R,T -> the 5 windows'
    // sides (index 0 = the focused window, on top). `seg`/`of` place same-side
    // windows into disjoint segments, exactly as fanSlots does.
    private static let colors: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 1.00), Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 1.00, green: 0.22, blue: 0.37),
    ]
    private static let layout: [(side: Side, seg: Int, of: Int)] = [
        (.top, 0, 2), (.bottom, 0, 1), (.left, 0, 1), (.right, 0, 1), (.top, 1, 2),
    ]
    private static let scatter: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (0.28, 0.22, 0.44, 0.46), (0.04, 0.06, 0.42, 0.40), (0.54, 0.02, 0.44, 0.38),
        (0.56, 0.50, 0.40, 0.46), (0.05, 0.52, 0.40, 0.42),
    ]

    // The fanned slab rect for window `i` on a `w`x`h` canvas, edge thickness `e`.
    private func slab(_ i: Int, _ w: CGFloat, _ h: CGFloat, _ e: CGFloat) -> CGRect {
        let L = Self.layout[i]
        let gap: CGFloat = 3
        func seg(_ run0: CGFloat, _ runLen: CGFloat) -> (CGFloat, CGFloat) {
            let len = (runLen - CGFloat(L.of - 1) * gap) / CGFloat(L.of)
            return (run0 + CGFloat(L.seg) * (len + gap), len)
        }
        switch L.side {
        case .top:    let (a, len) = seg(e, w - 2 * e); return CGRect(x: a, y: 0, width: len, height: h - e)
        case .bottom: let (a, len) = seg(e, w - 2 * e); return CGRect(x: a, y: e, width: len, height: h - e)
        case .left:   let (a, len) = seg(e, h - 2 * e); return CGRect(x: 0, y: a, width: w - e, height: len)
        case .right:  let (a, len) = seg(e, h - 2 * e); return CGRect(x: e, y: a, width: w - e, height: len)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let e = min(w, h) * 0.15                        // the edge-strip thickness
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.06))
                ForEach(0..<5, id: \.self) { i in
                    let front = i == 0
                    let s = Self.scatter[i]
                    let r = fanned ? slab(i, w, h, e)
                        : CGRect(x: s.x * w, y: s.y * h, width: s.w * w, height: s.h * h)
                    window(color: Self.colors[i], side: Self.layout[i].side, e: e,
                           fanned: fanned, front: front)
                        .frame(width: max(0, r.width), height: max(0, r.height))
                        .offset(x: r.minX, y: r.minY)
                        .zIndex(front ? 1 : 0)          // the focused window rides on top
                        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: fanned)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(playing ? 1 : 0.98)
            .opacity(playing ? 1 : 0.9)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
        }
        .heartbeat(Self.heartbeat, active: playing) { fanned.toggle() }
        .onChange(of: playing) { isOn in
            if !isOn { fanned = true }   // rest on the fan (the calm frame)
        }
    }

    // A slab: opaque body (so a front window occludes those behind), a colored
    // border, and -- when fanned -- a solid colored STRIP on its anchored edge
    // (the guaranteed-visible grabbable edge).
    private func window(color: Color, side: Side, e: CGFloat, fanned: Bool, front: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color(white: front ? 0.20 : 0.15))
            .overlay(alignment: stripAlignment(side)) {
                if fanned {
                    Rectangle().fill(color.opacity(front ? 0.95 : 0.8))
                        .frame(width: isVertical(side) ? e : nil,
                               height: isVertical(side) ? nil : e)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(color.opacity(fanned ? 0.95 : 0.5), lineWidth: front ? 2.5 : 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(front ? 0.18 : 0.1), radius: 2, y: 1)
    }

    private func isVertical(_ s: Side) -> Bool { s == .left || s == .right }
    private func stripAlignment(_ s: Side) -> Alignment {
        switch s {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
}
