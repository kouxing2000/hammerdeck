// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Toast (notify / alert)

@MainActor
enum Toast {
    private static var panels: [NSPanel] = []

    /// notify-style: top-right card with title + text. alert-style: centered.
    static func show(title: String?, text: String, centered: Bool, seconds: TimeInterval) {
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 360
        let pad: CGFloat = 14
        var y: CGFloat = pad

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 13)
        body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: 0)
        body.preferredMaxLayoutWidth = width - 2 * pad
        body.sizeToFit()
        y += body.frame.height
        content.addSubview(body)

        if let title, !title.isEmpty {
            y += 4
            let head = NSTextField(labelWithString: title)
            head.font = .boldSystemFont(ofSize: 13)
            head.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 18)
            content.addSubview(head)
            y += 18
        }
        y += pad

        let size = NSSize(width: width, height: y)
        let origin: NSPoint
        if centered {
            origin = NSPoint(x: screen.visibleFrame.midX - width / 2,
                             y: screen.visibleFrame.midY + 120)
        } else {
            origin = NSPoint(x: screen.visibleFrame.maxX - width - 16,
                             y: screen.visibleFrame.maxY - size.height - 16)
        }

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.ignoresMouseEvents = true
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.orderFrontRegardless()
        panels.append(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panels.removeAll { $0 === panel }
            }
        }
    }
}
