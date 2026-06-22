// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared base and the rationale for our own panels).

import AppKit
import QuartzCore

// MARK: - Chord which-key hint (floating card listing the follow keys)

/// The "which-key" hint for an armed chord: a small floating card listing the
/// follow keys live at the current level and what each does. Non-activating and
/// mouse-transparent -- purely informational, like BannerPanel. ChordCenter
/// shows it after a short delay and updates it as the chord descends levels.
@MainActor
final class ChordHintPanel {
    struct Row { let key: String; let label: String }

    private let panel: NSPanel
    private let container = NSView()
    private let stack = NSStackView()
    /// A thin strip along the bottom edge that depletes left-fixed over the
    /// timeout window -- the "press a key before this runs out" cue.
    private let barLayer = CALayer()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 12

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Left-anchored so depleting its width shrinks it toward the left.
        barLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        barLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        barLayer.cornerRadius = 1.5
        container.layer?.addSublayer(barLayer)

        panel.contentView = container
    }

    /// Rebuild the card for the given armed prefix + the follow keys at this
    /// level, size it to fit, and show it centered in the lower third of the
    /// main screen.
    func update(prefixMods: [String], prefixKey: String, rows: [Row],
                remaining: TimeInterval, total: TimeInterval) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let prefix = KeyGlyphs.prefix(prefixMods, prefixKey)
        stack.addArrangedSubview(headerLabel("\(prefix)  then\u{2026}"))
        for r in rows { stack.addArrangedSubview(rowLabel(r)) }
        stack.addArrangedSubview(footerLabel("esc  cancel"))

        container.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(200, fit.width)
        let h = fit.height
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.midX - w / 2
        let y = screen.minY + screen.height * 0.30
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()

        animateBar(width: w, remaining: remaining, total: total)
    }

    /// Set the bar to its current fraction (remaining/total) and animate it
    /// down to empty over `remaining` seconds, left edge fixed.
    private func animateBar(width w: CGFloat, remaining: TimeInterval, total: TimeInterval) {
        let inset: CGFloat = 14
        let full = max(0, w - inset * 2)
        let fraction = total > 0 ? max(0, min(1, remaining / total)) : 0
        // Position is set without implicit animation; the depletion is the only
        // thing that animates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.position = CGPoint(x: inset, y: 5)   // bottom band, below the footer
        barLayer.bounds = CGRect(x: 0, y: 0, width: 0, height: 3)   // model value = empty
        CATransaction.commit()

        barLayer.removeAnimation(forKey: "deplete")
        guard remaining > 0.05 else { return }
        let anim = CABasicAnimation(keyPath: "bounds.size.width")
        anim.fromValue = full * fraction
        anim.toValue = 0
        anim.duration = remaining
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        barLayer.add(anim, forKey: "deplete")
    }

    func close() { panel.orderOut(nil) }

    // MARK: rows

    private func headerLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 11, weight: .semibold)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func footerLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 10)
        f.textColor = .tertiaryLabelColor
        return f
    }

    private func rowLabel(_ r: Row) -> NSTextField {
        let f = NSTextField()
        f.isEditable = false; f.isBordered = false; f.drawsBackground = false
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: KeyGlyphs.glyph(r.key), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.controlAccentColor]))
        s.append(NSAttributedString(string: "   \(r.label)", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor]))
        f.attributedStringValue = s
        return f
    }
}
