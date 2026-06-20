// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Mouse locator (crosshair overlay that follows the pointer)

/// Draws four corner segments around the mouse pointer and follows it for a
/// few seconds, then fades out. Unlike the donor spoon, the overlay ignores
/// mouse events entirely -- clicks pass straight through to whatever is below.
@MainActor
final class MouseLocatorPanel {
    private let panel: NSPanel
    private let view: CrosshairView
    private var followTimer: Timer?
    private var closed = false
    private let onClose: () -> Void

    init(seconds: TimeInterval, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        view = CrosshairView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        panel.orderFrontRegardless()
        track()

        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.track() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { self.close() }
        }
    }

    private func track() {
        let p = NSEvent.mouseLocation
        view.point = NSPoint(x: p.x - panel.frame.minX, y: p.y - panel.frame.minY)
        view.needsDisplay = true
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

/// Four green corner segments pointing at `point` (donor visual parity).
final class CrosshairView: NSView {
    var point: NSPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        let outer: CGFloat = 60
        let inner: CGFloat = 20
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        for (sx, sy) in [(1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)] {
            path.move(to: NSPoint(x: point.x + outer * sx, y: point.y + outer * sy))
            path.line(to: NSPoint(x: point.x + inner * sx, y: point.y + inner * sy))
        }
        path.stroke()
    }
}
