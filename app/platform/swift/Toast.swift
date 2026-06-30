// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared FloatingPanel base and the rationale for our own panels).

import AppKit

// MARK: - Toast (notify / alert)

// The in-app "app-level" notification -- a macOS-notification-style card: app
// icon, a title/body hierarchy, a drop shadow, a slide-in + fade, and a top-right
// vertical STACK so several at once don't pile on the same spot. (The OTHER notify
// channel posts to the real Notification Center; see Native+Notifications.swift.)
@MainActor
enum Toast {
    private static var active: [NSPanel] = []   // the top-right stack, oldest first

    private static let width: CGFloat = 340
    private static let sideMargin: CGFloat = 14
    private static let topMargin: CGFloat = 14
    private static let stackGap: CGFloat = 10
    private static let maxStack = 5   // cap so a burst can't march off-screen

    /// notify-style: a top-right card (app icon + title + text) that stacks.
    /// alert-style: a brief centered card, no icon, no stacking.
    static func show(title: String?, text: String, centered: Bool, seconds: TimeInterval) {
        guard let screen = NSScreen.main else { return }

        let card = buildCard(title: title, text: text, showIcon: !centered)
        let size = card.frame.size

        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  collectionBehavior: [.canJoinAllSpaces, .transient, .fullScreenAuxiliary],
                                  hasShadow: true)
        panel.contentView = card
        panel.alphaValue = 0

        if centered {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                         y: screen.visibleFrame.midY + 120))
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        } else {
            // Start a touch to the right of the top slot, then slide left + fade in
            // while restack() drops any existing cards down to make room.
            let topY = screen.visibleFrame.maxY - topMargin - size.height
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - sideMargin + 26, y: topY))
            panel.orderFrontRegardless()
            active.append(panel)
            // Cap the stack -- evict the oldest so a burst can't run off-screen.
            if active.count > Self.maxStack, let oldest = active.first {
                dismiss(oldest, centered: false)
            }
            restack(on: screen)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; panel.animator().alphaValue = 1 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { dismiss(panel, centered: centered) }
        }
    }

    private static func dismiss(_ panel: NSPanel, centered: Bool) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                active.removeAll { $0 === panel }
                if !centered, let screen = NSScreen.main { restack(on: screen) }
            }
        })
    }

    // Lay out the top-right stack, newest at the top, others animating down.
    private static func restack(on screen: NSScreen) {
        var y = screen.visibleFrame.maxY - topMargin
        for panel in active.reversed() {   // last appended = newest = top slot
            let h = panel.frame.height
            let target = NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - sideMargin, y: y - h)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().setFrameOrigin(target)
            }
            y -= h + stackGap
        }
    }

    private static func buildCard(title: String?, text: String, showIcon: Bool) -> NSView {
        let hPad: CGFloat = 15, vPad: CGFloat = 13, gap: CGFloat = 11, iconSize: CGFloat = 40
        let leftInset = hPad + (showIcon ? iconSize + gap : 0)
        let textWidth = width - leftInset - hPad

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = textWidth
        body.setFrameSize(NSSize(width: textWidth, height: 0))
        body.sizeToFit()

        var head: NSTextField?
        if let title, !title.isEmpty {
            let h = NSTextField(wrappingLabelWithString: title)
            h.font = .systemFont(ofSize: 13.5, weight: .semibold)
            h.textColor = .labelColor
            h.preferredMaxLayoutWidth = textWidth
            h.setFrameSize(NSSize(width: textWidth, height: 0))
            h.sizeToFit()
            head = h
        }

        let headH = head.map { $0.frame.height + 3 } ?? 0
        let textBlock = headH + body.frame.height
        let contentH = max(showIcon ? iconSize : 0, textBlock)
        let totalH = contentH + vPad * 2

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: totalH))
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Top-align the text block (AppKit origin is bottom-left).
        var ty = totalH - vPad
        if let head {
            head.setFrameOrigin(NSPoint(x: leftInset, y: ty - head.frame.height))
            card.addSubview(head)
            ty -= head.frame.height + 3
        }
        body.setFrameOrigin(NSPoint(x: leftInset, y: ty - body.frame.height))
        card.addSubview(body)

        if showIcon, let icon = NSApp.applicationIconImage {
            let iv = NSImageView(frame: NSRect(x: hPad, y: totalH - vPad - iconSize,
                                               width: iconSize, height: iconSize))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(iv)
        }
        return card
    }
}
