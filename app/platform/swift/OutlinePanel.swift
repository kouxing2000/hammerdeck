// Panels.swift split: one self-owned native UI surface (see Panels.swift for the
// shared FloatingPanel base and the rationale for our own panels).
//
// A click-through accent BORDER drawn around a window region. Window Deck rings
// every deck member so membership is legible, in four styles (`kind`):
//   member -- subtle: every deck window, so you see which are in the deck.
//   focus  -- bold: the FOCUSED window in hero-off grid mode, so the active
//             tiled window stands out without a zoom to signal it.
//   hero   -- strong: the promoted window, so the active one stands out.
//   ghost  -- faint dashed: left at the hero's home SLOT while it's lifted to
//             centre, so you see where it drops back to.
// All share the accent color (uniform, not a rainbow) and differ only in weight/
// alpha/dash. Purely visual: `mouseTransparent`, floats above normal windows.
//
// Rendering: the panel is a STATIC transparent window covering the whole screen;
// the ring itself is a CAShapeLayer inside it, and the "ring flight" animates
// the LAYER, not the window. This is a hard constraint, not a taste call:
// NSWindow frame animation (`animator().setFrame`) is stepped on the app's main
// thread, and the deck dispatches synchronous AX setFrame calls (tens of ms
// each, blocking) at flight start -- which froze the window-based flight
// mid-air. A Core Animation layer flight is composited by the WindowServer's
// render server, so it stays smooth no matter what our main thread is doing.

import AppKit

@MainActor
final class OutlinePanel {
    private let panel: FloatingPanel
    private let host = NSView()          // layer-backed; its backing layer carries the hole mask
    private let ring = CAShapeLayer()
    private var style: OutlineStyle
    private var baseColor: NSColor
    private var screenHole: NSRect?      // AppKit screen coords; the stroke never paints inside

    init(kind: String, colorHex: String) {
        style = OutlineStyle.forKind(kind)
        baseColor = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        // Deliberately NOT .canJoinAllSpaces/.transient: a ring marks a window
        // that lives on ONE Space, so the ring must stay behind on a Space
        // switch exactly like the window does -- all-Spaces rings floated over
        // unrelated desktops. Default (managed) behavior binds the panel to
        // the Space it was shown on; NSPanels stay out of Mission Control.
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              level: .floating,
                              collectionBehavior: [.fullScreenAuxiliary],
                              keyable: false, mouseTransparent: true, hasShadow: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        host.wantsLayer = true
        panel.contentView = host
        ring.fillColor = nil
        applyStyle()
        host.layer?.addSublayer(ring)
    }

    /// Re-color in place (e.g. the user recolors a window in the picker).
    func setColor(_ colorHex: String) {
        baseColor = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        withoutImplicitAnimation {
            ring.strokeColor = baseColor.withAlphaComponent(style.alpha).cgColor
        }
    }

    /// Position the ring at `rect` (AppKit bottom-left screen coords) and show it.
    func place(_ rect: NSRect) {
        cover(for: rect)
        withoutImplicitAnimation {
            ring.removeAllAnimations()
            setRingFrame(local(rect))
        }
        panel.orderFrontRegardless()
    }

    /// Fly the ring to `rect` over `duration` seconds -- the "ring flight" that
    /// carries the eye between a grid slot and the hero rect. Real app windows
    /// can't tween (AX resize is discrete + async), but this layer animates in
    /// the render server, staying smooth even while the main thread blocks on
    /// the AX moves dispatched at flight start. Starts from the PRESENTATION
    /// state, so redirecting a mid-air flight bends the path instead of jumping.
    func animateTo(_ rect: NSRect, duration: Double) {
        cover(for: rect)
        panel.orderFrontRegardless()
        let f = local(rect)
        let from = ring.presentation() ?? ring
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let moves: [(key: String, from: Any?, to: Any?)] = [
            ("position", NSValue(point: from.position),
                         NSValue(point: CGPoint(x: f.midX, y: f.midY))),
            ("bounds",   NSValue(rect: from.bounds),
                         NSValue(rect: CGRect(origin: .zero, size: f.size))),
            ("path",     from.path, ringPath(f.size)),
        ]
        for m in moves {
            let a = CABasicAnimation(keyPath: m.key)
            a.fromValue = m.from
            a.toValue = m.to
            a.duration = duration
            a.timingFunction = timing
            ring.add(a, forKey: m.key)
        }
        withoutImplicitAnimation { setRingFrame(f) }   // model = destination; anims cover the travel
    }

    /// Re-style in place (e.g. a member border becomes the hero border on promote).
    func setStyle(_ kind: String) {
        style = OutlineStyle.forKind(kind)
        withoutImplicitAnimation { applyStyle() }
    }

    /// Clip the stroke OUT of `rect` (AppKit screen coords; nil = no hole).
    /// The overlays float above every normal window, so a member border whose
    /// slot runs under the hero would otherwise draw its lines ACROSS the hero;
    /// the deck passes the hero rect here so borders never paint over it.
    /// The mask lives on the HOST layer in panel (screen) coordinates, so it
    /// stays put while the ring flies through it.
    func setHole(_ rect: NSRect?) {
        screenHole = rect
        rebuildMask()
    }

    /// Hide without destroying -- the next place()/animateTo() re-shows. Window
    /// Deck hides a ring while the USER drags/resizes its window (live AX
    /// tracking would visibly trail the drag), then re-shows it at the real
    /// frame once the window has settled.
    /// ACCEPTED LIMITATION (owner call, 2026-07-01): without .canJoinAllSpaces
    /// an ordered-out panel joins the ACTIVE Space on its next order-front, so
    /// hide -> switch Space -> settle re-show can place a ring over the wrong
    /// desktop until its next hide/show cycle. Rare (needs a Space switch
    /// inside the ~0.35s settle window) and self-limiting; revisit with an
    /// isOnActiveSpace guard if it ever bites in practice.
    func hide() { panel.orderOut(nil) }

    func close() { panel.orderOut(nil) }

    // MARK: - Geometry (screen coords -> static panel -> layer)

    /// Size the panel to the SCREEN holding `rect` (one deck = one screen, so
    /// this settles on first placement). The window never moves after that --
    /// only the ring layer does. Cross-screen re-covers snap rather than tween
    /// (the deck never asks for one).
    private func cover(for rect: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.screens.first
        guard let target = screen?.frame else { return }
        let scale = screen?.backingScaleFactor ?? 2
        if ring.contentsScale != scale { ring.contentsScale = scale }
        guard panel.frame != target else { return }
        panel.setFrame(target, display: false)
        rebuildMask()
    }

    private func local(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX - panel.frame.minX, y: rect.minY - panel.frame.minY,
               width: rect.width, height: rect.height)
    }

    private func setRingFrame(_ f: NSRect) {
        ring.position = CGPoint(x: f.midX, y: f.midY)
        ring.bounds = CGRect(origin: .zero, size: f.size)
        ring.path = ringPath(f.size)
    }

    /// Rounded-rect stroke path for a ring of `size`, inset so the stroke hugs
    /// the edge. Radius is clamped so tiny frames can't underflow CGPath's
    /// rounded-rect preconditions.
    private func ringPath(_ size: CGSize) -> CGPath {
        let lw = style.width
        var r = CGRect(origin: .zero, size: size).insetBy(dx: lw / 2, dy: lw / 2)
        if r.width < 0 || r.height < 0 { r = CGRect(origin: r.origin, size: .zero) }
        let radius = min(style.radius, r.width / 2, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func applyStyle() {
        ring.lineWidth = style.width
        ring.lineDashPattern = style.dashed ? [6, 4] : nil
        ring.strokeColor = baseColor.withAlphaComponent(style.alpha).cgColor
        ring.path = ringPath(ring.bounds.size)
    }

    /// Even-odd mask: panel bounds minus the hole. Rebuilt whenever the hole or
    /// the panel's coverage changes; nil hole drops the mask entirely.
    private func rebuildMask() {
        guard let layer = host.layer else { return }
        guard let hole = screenHole else {
            withoutImplicitAnimation { layer.mask = nil }
            return
        }
        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(local(hole))
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = path
        withoutImplicitAnimation { layer.mask = mask }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

private struct OutlineStyle {
    var width: CGFloat
    var radius: CGFloat
    var alpha: CGFloat
    var dashed: Bool
    static func forKind(_ kind: String) -> OutlineStyle {
        switch kind {
        case "hero":  return OutlineStyle(width: 4, radius: 11, alpha: 1.0,  dashed: false)
        // focus: a bold, fully-opaque ring at a member's slot -- twice the member
        // weight so the focused tiled window reads at a glance (hero-off grid mode).
        case "focus": return OutlineStyle(width: 4, radius: 10, alpha: 1.0,  dashed: false)
        case "ghost": return OutlineStyle(width: 2, radius: 10, alpha: 0.35, dashed: true)
        default:      return OutlineStyle(width: 2, radius: 10, alpha: 0.55, dashed: false)  // member
        }
    }
}

extension NSColor {
    /// "#RRGGBB" (or "RRGGBB") -> sRGB color; nil for empty/malformed input.
    /// Shared by the outline overlays and the window picker's color swatches.
    convenience init?(hexRGB: String) {
        let s = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
