// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Banner (full-width top overlay, e.g. sleep countdown)

@MainActor
final class BannerPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init(text: String) {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 44
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)

        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 0.85).cgColor

        label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 10, width: rect.width, height: 26)
        label.autoresizingMask = [.width]
        content.addSubview(label)

        panel.contentView = content
        panel.orderFrontRegardless()
    }

    func setText(_ text: String) { label.stringValue = text }

    func close() { panel.orderOut(nil) }
}
