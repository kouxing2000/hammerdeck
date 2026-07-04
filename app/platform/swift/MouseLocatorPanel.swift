// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared FloatingPanel base and the rationale for our own panels).

import AppKit
import QuartzCore

// MARK: - Mouse locator (animated glow + radar rings that follow the pointer)

/// Draws a pulsing green HALO with radar RINGS pinging outward from the mouse
/// pointer, follows it for a few seconds, then fades out. Purely visual: the
/// overlay ignores mouse events entirely -- clicks pass straight through to
/// whatever is below (unlike the donor spoon, which swallowed the click).
@MainActor
final class MouseLocatorPanel {
    private let panel: FloatingPanel
    private let view: LocatorView
    private var followTimer: Timer?
    private var closed = false
    private let onClose: () -> Void

    init(seconds: TimeInterval, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Span the FULL desktop (union of every screen), not just the one screen
        // the pointer sits on at construction. A warp that hops the pointer to
        // another display -- locate_pointer's "center on next screen",
        // window_snap's move-to-next/prev-screen -- has NOT yet updated
        // NSEvent.mouseLocation when locate fires (CGWarpMouseCursorPosition is
        // not reflected instantly), so a single-screen panel would pin to the OLD
        // screen and draw the locator outside its bounds -- invisible on the
        // screen the pointer actually landed on. A desktop-spanning panel tracks
        // the pointer wherever it ends up, including a mid-flash screen hop.
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        let frame = union.isNull
            ? (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
            : union

        panel = FloatingPanel(contentRect: frame)

        view = LocatorView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        panel.orderFrontRegardless()
        track()

        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.track() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { self.close() }
        }
    }

    private func track() {
        let p = NSEvent.mouseLocation
        view.point = NSPoint(x: p.x - panel.frame.minX, y: p.y - panel.frame.minY)
    }

    func close() {
        guard !closed else { return }
        closed = true
        followTimer?.invalidate()
        followTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                self.onClose()
            }
        })
    }
}

/// A pulsing radial-gradient HALO plus two staggered radar RINGS, all centred on
/// `point` and driven by Core Animation (so the follow just repositions the
/// layers -- the pulse/ping keep running). The rings expand by animating their
/// PATH (not a transform scale) so the stroke stays a thin, constant hairline as
/// they grow, instead of thickening.
final class LocatorView: NSView {
    private let halo = CAGradientLayer()
    private let ring1 = CAShapeLayer()
    private let ring2 = CAShapeLayer()

    // A fixed layer box comfortably larger than the biggest ring, so an expanding
    // ring never clips; `point` centres the box on the pointer.
    private static let box: CGFloat = 200
    private static let ringMin: CGFloat = 6
    private static let ringMax: CGFloat = 74
    private static let color = NSColor.systemGreen

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setupHalo()
        setupRing(ring1, delay: 0)
        setupRing(ring2, delay: 0.8)   // half-period stagger -> a continuous ping
        layer?.addSublayer(halo)        // glow sits behind the rings
        layer?.addSublayer(ring1)
        layer?.addSublayer(ring2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// Reposition every layer onto the pointer WITHOUT an implicit move animation
    /// (that would make the locator lag/slide behind a fast pointer).
    var point: NSPoint = .zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.position = point
            ring1.position = point
            ring2.position = point
            CATransaction.commit()
        }
    }

    private func setupHalo() {
        halo.type = .radial
        halo.colors = [LocatorView.color.withAlphaComponent(0.55).cgColor,
                       LocatorView.color.withAlphaComponent(0.0).cgColor]
        halo.locations = [0, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        // A ~86px glow (the gradient's own bounds stay small; the ring box is the
        // shared coordinate frame, but the halo just needs to centre on `point`).
        halo.bounds = CGRect(x: 0, y: 0, width: 86, height: 86)
        halo.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.65
        scale.toValue = 1.15
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.5
        op.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [scale, op]
        group.duration = 0.75            // 1.5s full breath (autoreverses)
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(group, forKey: "breathe")
    }

    private func setupRing(_ ring: CAShapeLayer, delay: Double) {
        let b = LocatorView.box
        ring.bounds = CGRect(x: 0, y: 0, width: b, height: b)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = LocatorView.color.cgColor
        ring.lineWidth = 2.5
        ring.path = LocatorView.circle(LocatorView.ringMin)   // static start state

        let path = CABasicAnimation(keyPath: "path")
        path.fromValue = LocatorView.circle(LocatorView.ringMin)
        path.toValue = LocatorView.circle(LocatorView.ringMax)
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.95
        op.toValue = 0.0
        let lw = CABasicAnimation(keyPath: "lineWidth")
        lw.fromValue = 3.0
        lw.toValue = 0.75
        let group = CAAnimationGroup()
        group.animations = [path, op, lw]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ping")
    }

    /// A circle of radius `r` centred in the box (so `position` = pointer centres
    /// it on the pointer).
    private static func circle(_ r: CGFloat) -> CGPath {
        let c = box / 2
        return CGPath(ellipseIn: CGRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r), transform: nil)
    }
}
