// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared base and the rationale for our own panels).

import AppKit
import QuartzCore

// MARK: - Chord which-key hint (floating card listing the follow keys)

/// The "which-key" hint for an armed chord: a small floating card listing the
/// follow keys live at the current level and what each does. Non-activating and
/// mouse-transparent -- purely informational, like BannerPanel. ChordCenter
/// shows it after a short delay and updates it as the chord descends levels.
///
/// Styled to match its sibling HUDs (HyperHintPanel / WindowModeHUDPanel): a
/// real macOS `.hudWindow` vibrancy card with boxed key-caps and fixed-width
/// caps that align every follow-key's label into a tidy column -- one HUD
/// language across the app, and the alignment that makes the labels easy to
/// read. The depleting accent bar along the bottom edge stays as the "press a
/// key before this runs out" cue.
@MainActor
final class ChordHintPanel {
    struct Row { let key: String; let label: String }

    private let panel: NSPanel
    private let effect = NSVisualEffectView()
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

        // Real macOS vibrancy, clipped to a rounded rect; the panel casts the shadow.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 15, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // Left-anchored so depleting its width shrinks it toward the left.
        barLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        barLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        barLayer.cornerRadius = 1.5
        effect.layer?.addSublayer(barLayer)

        panel.contentView = effect
    }

    /// Rebuild the card for the given armed prefix + the follow keys at this
    /// level, size it to fit, and show it centered in the lower third of the
    /// main screen.
    func update(prefixMods: [String], prefixKey: String, rows: [Row],
                remaining: TimeInterval, total: TimeInterval) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview(headerView(prefixMods, prefixKey))
        stack.addArrangedSubview(listView(rows))
        stack.addArrangedSubview(footerView())

        effect.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(220, fit.width)
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
        let inset: CGFloat = 16   // tracks the stack's left content gutter
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

    // MARK: - Pieces

    /// Header: the armed prefix as boxed caps (one per modifier + the key),
    /// then a dim "then..." so it reads as "press THIS, then a follow key".
    private func headerView(_ mods: [String], _ key: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        for g in KeyGlyphs.modifiers(mods).map({ String($0) }) {
            row.addArrangedSubview(keyCap(g, fontSize: 11, height: 20))
        }
        row.addArrangedSubview(keyCap(KeyGlyphs.glyph(key), fontSize: 11, height: 20))
        let then = NSTextField(labelWithString: "then\u{2026}")
        then.font = .systemFont(ofSize: 12, weight: .regular)
        then.textColor = .secondaryLabelColor
        row.addArrangedSubview(then)
        return row
    }

    /// Footer: an `esc` cap + "cancel", dim.
    private func footerView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.addArrangedSubview(keyCap("esc", fontSize: 10, height: 18))
        let cancel = NSTextField(labelWithString: "cancel")
        cancel.font = .systemFont(ofSize: 11)
        cancel.textColor = .tertiaryLabelColor
        row.addArrangedSubview(cancel)
        return row
    }

    /// One [key-cap  label] row per follow key. Fixed-width caps make every
    /// label start at the same x, so the labels read as a tidy column (the fix
    /// for them being hard to track) without NSGridView's column-sizing quirks.
    private func listView(_ rows: [Row]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 7
        for r in rows {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 11
            line.addArrangedSubview(keyCap(KeyGlyphs.glyph(r.key), fontSize: 13, height: 24, fixedWidth: 26))
            line.addArrangedSubview(labelField(r.label))
            col.addArrangedSubview(line)
        }
        return col
    }

    private func labelField(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: 13)
        f.textColor = .labelColor
        return f
    }

    /// A boxed key-cap: the glyph in a faint rounded rect, like a keyboard key.
    /// `fixedWidth` pins the cap to a constant width so a column of single-key
    /// caps aligns its labels; otherwise the cap hugs its glyph (header/footer).
    private func keyCap(_ glyph: String, fontSize: CGFloat, height: CGFloat,
                        fixedWidth: CGFloat? = nil) -> NSView {
        let label = NSTextField(labelWithString: glyph)
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let cap = NSView()
        cap.wantsLayer = true
        cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        cap.layer?.cornerRadius = 5
        cap.layer?.borderWidth = 1
        cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        cap.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(label)

        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        if let fw = fixedWidth {
            // Pin to fw for column alignment, but let a wide glyph grow rather
            // than clip (KeyGlyphs can return multi-char glyphs like arrows).
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: fw).isActive = true
            let pin = cap.widthAnchor.constraint(equalToConstant: fw)
            pin.priority = .defaultHigh
            pin.isActive = true
            cap.widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 14).isActive = true
        } else {
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
            let fit = cap.widthAnchor.constraint(equalTo: label.widthAnchor, constant: 14)
            fit.priority = .defaultHigh
            fit.isActive = true
        }
        return cap
    }
}
