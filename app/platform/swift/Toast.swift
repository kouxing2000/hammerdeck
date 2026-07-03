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
    // The whole notify stack lives on ONE screen for its lifetime: the cursor's
    // screen at the moment the stack was empty. Pinning it means a later card --
    // or a restack after a dismiss -- never yanks an existing card to another
    // display when the cursor has since moved. Reset to nil when the stack drains.
    private static var stackScreen: NSScreen?

    // The quiet "flash" chip is a SINGLE slot (top-center), not a stack: each new
    // flash replaces the last so rapid shortcut presses can never pile up. `flashSeq`
    // lets a superseded panel's dismiss timer bow out (a newer flash owns the slot).
    private static var flashPanel: NSPanel?
    private static var flashSeq = 0

    private static let width: CGFloat = 340
    private static let sideMargin: CGFloat = 14
    private static let topMargin: CGFloat = 14
    private static let stackGap: CGFloat = 10
    private static let maxStack = 5   // cap so a burst can't march off-screen

    /// notify-style: a top-right card (app icon + title + text) that stacks.
    /// alert-style: a brief centered card, no icon, no stacking.
    static func show(title: String?, text: String, centered: Bool, seconds: TimeInterval) {
        // Land on the screen the user is on (cursor), not NSScreen.main -- so a
        // notification (incl. an automated-run toast fired while you're at another
        // display) lands where you're looking, consistent with the flash chip. A
        // centered alert picks it fresh each time; the top-right STACK pins to one
        // screen for its lifetime (see stackScreen) so a card never splits across
        // or teleports between displays when the cursor moves mid-stack.
        let screen: NSScreen?
        if centered {
            screen = activeScreen()
        } else {
            if active.isEmpty { stackScreen = activeScreen() }
            screen = stackScreen
        }
        guard let screen else { return }

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

    /// The quiet single-slot "flash" chip: a compact top-center pill (SF Symbol
    /// glyph + one line) that confirms a MANUAL shortcut fired and names WHICH
    /// action ran. Replaces any in-flight flash in place (no pile-up) and fades on
    /// its own. Distinct in shape and spot from the stacking top-right notify card,
    /// so at-keyboard confirmation and away-from-keyboard notifications never fight.
    static func flash(symbol: String?, text: String, seconds: TimeInterval) {
        // Land on the screen the user is actually on -- the one under the cursor --
        // NOT NSScreen.main (the menu-bar/primary display), which on a multi-monitor
        // setup is routinely not where you're working. A manual-shortcut confirmation
        // has to appear where you're looking, or it may as well not fire.
        guard let screen = activeScreen() else { return }

        // Take over the single slot: drop any flash still on screen at once.
        flashPanel?.orderOut(nil)
        flashPanel = nil

        let card = buildFlashPill(symbol: symbol, text: text)
        let size = card.frame.size
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  collectionBehavior: [.canJoinAllSpaces, .transient, .fullScreenAuxiliary],
                                  hasShadow: true)
        panel.contentView = card
        panel.alphaValue = 0
        // Top-center, just under the menubar (where Hammerdeck lives).
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                                     y: screen.visibleFrame.maxY - size.height - 20))
        panel.orderFrontRegardless()
        flashPanel = panel
        flashSeq += 1
        let mySeq = flashSeq
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; panel.animator().alphaValue = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                // A newer flash has taken the slot -- let it own the dismiss.
                guard flashSeq == mySeq, flashPanel === panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                    completionHandler: {
                        MainActor.assumeIsolated {
                            panel.orderOut(nil)
                            if flashPanel === panel { flashPanel = nil }
                        }
                    })
            }
        }
    }

    /// The screen the user is on right now -- the one under the mouse cursor -- so
    /// a confirmation lands where they're looking. Falls back to main if the cursor
    /// isn't inside any screen's frame (rare, e.g. mid-transition). Mirrors
    /// MouseLocatorPanel's cursor-based targeting.
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private static func buildFlashPill(symbol: String?, text: String) -> NSView {
        let hPad: CGFloat = 13, vPad: CGFloat = 9, gap: CGFloat = 8, glyphSize: CGFloat = 15

        var glyph: NSImage?
        if let sym = symbol, !sym.isEmpty {
            glyph = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold))
            glyph?.isTemplate = true
        }
        let hasGlyph = glyph != nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        // Cap the width so a long "Feature -- Action" can't grow an unbounded pill
        // (which, centered, would overflow a narrow screen / push origin.x negative).
        let maxLabelW: CGFloat = 360
        if label.frame.width > maxLabelW {
            label.setFrameSize(NSSize(width: maxLabelW, height: label.frame.height))
        }

        let contentH = max(glyphSize, label.frame.height)
        let totalH = contentH + vPad * 2
        let totalW = hPad + (hasGlyph ? glyphSize + gap : 0) + label.frame.width + hPad

        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: totalW, height: totalH))
        card.material = .hudWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = totalH / 2   // pill
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        var x = hPad
        if let g = glyph {
            let iv = NSImageView(frame: NSRect(x: x, y: (totalH - glyphSize) / 2,
                                               width: glyphSize, height: glyphSize))
            iv.image = g
            iv.contentTintColor = .labelColor
            iv.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(iv)
            x += glyphSize + gap
        }
        label.setFrameOrigin(NSPoint(x: x, y: (totalH - label.frame.height) / 2))
        card.addSubview(label)
        return card
    }

    private static func dismiss(_ panel: NSPanel, centered: Bool) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                active.removeAll { $0 === panel }
                if !centered {
                    if active.isEmpty { stackScreen = nil }            // drained -- unpin
                    else if let screen = stackScreen { restack(on: screen) }
                }
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
