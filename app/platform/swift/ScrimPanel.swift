// Panels.swift split: one self-owned native UI surface (see Panels.swift for the
// shared FloatingPanel base and the rationale for our own panels).
//
// The Window Deck "container" surface: a full-screen DIM scrim with a HOLE
// punched through for each deck window. The deck windows show through their
// holes at full brightness; every OTHER window on that screen is dimmed behind
// the scrim -- an Expose/Stage-Manager focus effect that frames the deck as a
// place. The deck's title/exit affordance is a SEPARATE draggable card (see
// DeckWidgetPanel) floating above this click-through scrim.
//
// Why a hole-punched overlay ON TOP rather than a backdrop window BEHIND the
// deck: a backdrop that sits behind the deck windows but in front of everything
// else is an impossible z-interleave -- macOS window LEVELS are global bands,
// and we cannot staple our panel into the middle of OTHER apps' window stack
// (the same hard z-order wall the ring overlays live with; see OutlinePanel and
// the CLAUDE.md z-order note). A scrim above everything with cutouts needs zero
// window reordering: it composites in the render server exactly like the rings.
//
// This (with DeckWidgetPanel) replaces the old BannerPanel for the deck: both
// are full-screen / deck-screen elements the deck re-anchors on every
// screenChanged, so they can never be orphaned onto another display the way a
// fixed-rect banner was.
//
// Rendering: the scrim is drawn in a layer-backed NSView via Core Graphics --
// fill the bounds with the dim color, then `.clear`-blend each hole rect. The
// clear blend is idempotent, so OVERLAPPING holes (a hero cell overlapping a
// member cell) punch cleanly -- unlike an even-odd mask, which would XOR the
// overlap back to opaque. Holes SNAP on update (deck transitions are discrete);
// the smooth motion is carried by the ring flights over the top.

import AppKit

@MainActor
final class ScrimPanel {
    private let panel: FloatingPanel
    private let view = ScrimView()

    /// `screen` is an AppKit bottom-left GLOBAL rect (the caller flips it from
    /// the top-left global frame, the same flip BannerPanel / outline use).
    init(screen: NSRect, dim: CGFloat) {
        // One notch BELOW the rings (.floating): the scrim dims, the rings
        // accent on top of it. Both sit above normal windows.
        panel = FloatingPanel(
            contentRect: screen,
            level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1),
            // A ring marks windows on ONE Space; the scrim frames that same deck,
            // so it must stay on the deck's Space too -- NOT .canJoinAllSpaces
            // (that would dim every desktop). Matches OutlinePanel's behavior.
            collectionBehavior: [.fullScreenAuxiliary],
            keyable: false, mouseTransparent: true, hasShadow: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false

        view.frame = NSRect(origin: .zero, size: screen.size)
        view.dim = dim
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        panel.orderFrontRegardless()
    }

    /// Holes in AppKit bottom-left GLOBAL coords; stored view-local (the draw
    /// runs in the view's own space).
    func setHoles(_ global: [NSRect]) {
        let o = panel.frame.origin
        view.holes = global.map {
            NSRect(x: $0.minX - o.x, y: $0.minY - o.y, width: $0.width, height: $0.height)
        }
    }

    func setDim(_ d: CGFloat) { view.dim = d }

    /// Re-cover a (possibly moved/resized) screen after a display reconfig, so
    /// the scrim tracks its deck's screen instead of stranding at a stale rect.
    func reanchor(_ screen: NSRect) {
        panel.setFrame(screen, display: true)
        view.frame = NSRect(origin: .zero, size: screen.size)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }
}

/// The dim + hole-punch drawing. Redrawn only on hole/dim changes (deck
/// transitions are discrete), so the main-thread draw cost never competes with
/// the AX-blocking frame moves the way a per-frame animation would.
private final class ScrimView: NSView {
    var holes: [NSRect] = [] { didSet { needsDisplay = true } }
    var dim: CGFloat = 0.5 { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.07, alpha: dim).cgColor)
        ctx.fill(bounds)
        // Clear-blend each hole: idempotent, so overlapping holes punch cleanly.
        ctx.setBlendMode(.clear)
        for h in holes {
            let r = h.intersection(bounds)
            if r.isEmpty { continue }
            let radius = min(9, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }
}
