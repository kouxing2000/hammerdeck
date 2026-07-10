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
        // A SMALL panel that FOLLOWS the pointer by repositioning its origin each
        // frame (in global screen coords), with the halo pinned at its centre.
        //
        // The prior design was one giant panel spanning the union of every screen,
        // mapping the pointer into that panel's own coordinate space. But the union
        // is as TALL as the tallest display, and a shorter display (a laptop's
        // built-in screen beside a bigger external) sits at the BOTTOM of it -- so a
        // pointer on the short screen mapped into the empty band ABOVE it (no pixels
        // there) and the locator was invisible on that screen. A small follow-panel
        // has no union and no dead zone: it crosses displays naturally and is immune
        // to the bottom-vs-top origin flip (the halo is centred, symmetric).
        // Size the locator to the display it lands on: a fixed point size looks
        // tiny on a large high-resolution desktop (a big external beside a laptop).
        let scale = MouseLocatorPanel.locatorScale()
        view = LocatorView(scale: scale)
        view.point = NSPoint(x: view.frame.midX, y: view.frame.midY)   // halo centred

        panel = FloatingPanel(contentRect: view.frame)
        panel.contentView = view
        recenter()                       // sit on the pointer BEFORE first paint
        panel.orderFrontRegardless()

        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.recenter() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { self.close() }
        }
    }

    /// Centre the panel on the current pointer, in global (Cocoa, bottom-left)
    /// screen coords. setFrameOrigin -- unlike setFrame -- skips constrainFrameRect,
    /// so the panel is free to sit under the menu bar or on a negative-origin
    /// display without being nudged back onto the primary screen.
    private func recenter() {
        let p = NSEvent.mouseLocation
        let half = panel.frame.width / 2
        panel.setFrameOrigin(NSPoint(x: p.x - half, y: p.y - half))
    }

    /// How much to grow the locator, from the height of the display the pointer is
    /// on versus a ~900pt baseline. Clamped so it never shrinks below the original
    /// look (>= 1) and never runs away on a very large desktop (<= 3). Points, not
    /// pixels: a Retina screen already normalises DPI, so this tracks how much
    /// SCREEN the halo covers, which is what "too small on the big display" is about.
    private static func locatorScale() -> CGFloat {
        let p = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        let h = screen?.frame.height ?? 900
        return min(3.0, max(1.0, h / 900))
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

    // Every dimension is a base value times `scale` (from MouseLocatorPanel, so the
    // locator grows on a large high-resolution display). `box` is the layer frame,
    // kept comfortably larger than the biggest ring so an expanding ring never
    // clips; `point` centres it on the pointer.
    static let baseBox: CGFloat = 200
    private let scale: CGFloat
    private let box: CGFloat
    private let ringMin: CGFloat
    private let ringMax: CGFloat
    private let haloSize: CGFloat
    private static let color = NSColor.systemGreen

    init(scale: CGFloat) {
        self.scale = scale
        self.box = LocatorView.baseBox * scale
        self.ringMin = 6 * scale
        self.ringMax = 74 * scale
        self.haloSize = 86 * scale
        super.init(frame: NSRect(x: 0, y: 0, width: box, height: box))
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
        // A ~86pt glow (the gradient's own bounds stay small; the ring box is the
        // shared coordinate frame, but the halo just needs to centre on `point`).
        halo.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
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
        ring.bounds = CGRect(x: 0, y: 0, width: box, height: box)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = LocatorView.color.cgColor
        ring.lineWidth = 2.5 * scale
        ring.path = circle(ringMin)   // static start state

        let path = CABasicAnimation(keyPath: "path")
        path.fromValue = circle(ringMin)
        path.toValue = circle(ringMax)
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.95
        op.toValue = 0.0
        let lw = CABasicAnimation(keyPath: "lineWidth")
        lw.fromValue = 3.0 * scale
        lw.toValue = 0.75 * scale
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
    private func circle(_ r: CGFloat) -> CGPath {
        let c = box / 2
        return CGPath(ellipseIn: CGRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r), transform: nil)
    }
}
