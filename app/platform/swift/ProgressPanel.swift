// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Progress strip (thin bar across the bottom of the main screen)

/// CountDown-style progress indicator: a few-pixel strip pinned to the bottom
/// edge -- elapsed portion red, remaining portion green (donor parity).
@MainActor
final class ProgressPanel {
    private let panel: NSPanel
    private let elapsedView = NSView()
    private let remainingView = NSView()
    private static let height: CGFloat = 5

    init() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.minX, y: screen.minY,
                          width: screen.width, height: ProgressPanel.height)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.75
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        elapsedView.wantsLayer = true
        elapsedView.layer?.backgroundColor = NSColor.systemRed.cgColor
        remainingView.wantsLayer = true
        remainingView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        content.addSubview(elapsedView)
        content.addSubview(remainingView)
        panel.contentView = content
        panel.orderFrontRegardless()
        setProgress(0)
    }

    func setProgress(_ fraction: Double) {
        let f = CGFloat(max(0, min(1, fraction)))
        let w = panel.frame.width
        elapsedView.frame = NSRect(x: 0, y: 0, width: w * f, height: ProgressPanel.height)
        remainingView.frame = NSRect(x: w * f, y: 0, width: w * (1 - f), height: ProgressPanel.height)
    }

    func close() { panel.orderOut(nil) }
}
