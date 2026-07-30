// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared base and the rationale for our own panels).

import AppKit
import QuartzCore

// MARK: - Chord which-key hint (floating card listing the follow keys)

/// The "which-key" hint for an armed chord: a small floating card listing the
/// follow keys live at the current level and what each does. Non-activating,
/// and -- like HyperHintPanel, whose amber caps arm the chord this card
/// completes -- it answers the POINTER: a row highlights on hover and picks its
/// follow key on click, so a chord started with the mouse can be finished with
/// it. Clicking anywhere else on the card cancels, the pointer twin of the `esc`
/// its own footer advertises. ChordCenter shows it after a short delay and
/// updates it as the chord descends levels.
///
/// Styled to match its sibling HUDs (HyperHintPanel / WindowModeHUDPanel): a
/// real macOS `.hudWindow` vibrancy card with boxed key-caps and fixed-width
/// caps that align every follow-key's label into a tidy column -- one HUD
/// language across the app, and the alignment that makes the labels easy to
/// read. The depleting accent bar along the bottom edge stays as the "press a
/// key before this runs out" cue.
@MainActor
final class ChordHintPanel {
    struct Row { let key: String; let label: String; let icon: String? }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80))
    private var effect: NSVisualEffectView { hud.effect }
    private var stack: NSStackView { hud.stack }
    /// A thin strip along the bottom edge that depletes left-fixed over the
    /// timeout window -- the "press a key before this runs out" cue.
    private let barLayer = CALayer()

    /// Called with the follow key of the row the user CLICKED -- the pointer
    /// twin of typing it. The owner decides whether that key is still live.
    var onChoose: ((String) -> Void)?
    /// Called on a click that hit the card but no row: cancel, same as `esc`.
    var onDismiss: (() -> Void)?

    init() {
        // Interactive, unlike its informational siblings -- see the class note.
        hud.ignoresMouseEvents = false
        hud.onBackgroundClick = { [weak self] in self?.onDismiss?() }

        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 15, right: 18)

        // Left-anchored so depleting its width shrinks it toward the left.
        barLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        barLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        barLayer.cornerRadius = 1.5
        effect.layer?.addSublayer(barLayer)
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

        let w = hud.present(minWidth: 220)
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

    func close() { hud.orderOut(nil) }

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

    /// Per-follow-key cap colors, cycled by row so each key reads as its own
    /// distinct chip -- easier to scan than a column of identical caps. Native
    /// system colors so they stay vivid yet at home on the dark HUD.
    private static let capPalette: [NSColor] = [
        .systemTeal, .systemOrange, .systemPink, .systemGreen,
        .systemPurple, .systemYellow, .systemBlue, .systemRed,
    ]

    /// One [key-cap  label] row per follow key. Fixed-width caps make every
    /// label start at the same x, so the labels read as a tidy column (the fix
    /// for them being hard to track) without NSGridView's column-sizing quirks.
    private func listView(_ rows: [Row]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 7
        for (i, r) in rows.enumerated() {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 11
            let tint = Self.capPalette[i % Self.capPalette.count]
            line.addArrangedSubview(keyCap(KeyGlyphs.glyph(r.key), fontSize: 13, height: 24,
                                           fixedWidth: 26, tint: tint))
            line.addArrangedSubview(iconView(r.icon))
            line.addArrangedSubview(labelField(r.label))
            col.addArrangedSubview(ChordRowView(line, key: r.key,
                                                onClick: { [weak self] k in self?.onChoose?(k) }))
        }
        return col
    }

    /// The action's leading glyph, in a FIXED-width box so every label starts at
    /// the same x -- an empty box when the row has no icon, so the icon column
    /// never goes ragged. Dim (secondary) so the vivid key-cap stays the row's
    /// color anchor and the glyph reads as quiet reinforcement, like the palette.
    private func iconView(_ symbol: String?) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 18).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        guard let symbol,
              let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                  .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return box }
        img.isTemplate = true
        let iv = NSImageView(image: img)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentTintColor = .secondaryLabelColor
        iv.imageScaling = .scaleProportionallyDown
        box.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 18),
            iv.heightAnchor.constraint(equalToConstant: 18),
        ])
        return box
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
    /// `tint` colors the cap (fill/border/glyph) so each follow key reads as a
    /// distinct chip; nil gives the neutral white cap (header/footer).
    private func keyCap(_ glyph: String, fontSize: CGFloat, height: CGFloat,
                        fixedWidth: CGFloat? = nil, tint: NSColor? = nil) -> NSView {
        KeyCap.make(glyph, fontSize: fontSize, height: height, fixedWidth: fixedWidth, tint: tint)
    }
}

/// One clickable follow-key row: wraps the [cap  glyph  label] line in a hit
/// target that highlights on hover and reports its key on click. The wrapper
/// exists because the line itself is an NSStackView sized to its content --
/// hovering the GAPS between cap, glyph and label has to count as hovering the
/// row, or the target would be three disjoint slivers.
@MainActor
private final class ChordRowView: NSView {
    private let key: String
    private let onClick: (String) -> Void
    private var tracking: NSTrackingArea?
    private var pressing = false

    init(_ content: NSView, key: String, onClick: @escaping (String) -> Void) {
        self.key = key
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // A small bleed so the highlight reads as a row band, not a tight box.
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t); tracking = nil }
        // `.activeAlways`: the panel is non-activating and never key.
        // `.inVisibleRect`: this view is created at .zero and sized entirely by
        // Auto Layout inside the stack, so a rect captured now would be stale.
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    private func setFill(_ alpha: CGFloat) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }

    override func mouseEntered(with event: NSEvent) { setFill(0.10) }
    override func mouseExited(with event: NSEvent) { pressing = false; setFill(0) }

    /// The panel is never key, so without this the first click would be
    /// swallowed as an activation instead of picking the row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        setFill(0.20)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { return }
        setFill(isInside(event) ? 0.20 : 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        setFill(isInside(event) ? 0.10 : 0)
        if isInside(event) { onClick(key) }
    }

    private func isInside(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }
}
