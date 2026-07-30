// Panels.swift split: one self-owned native UI surface (see Panels.swift for
// the shared FloatingPanel / VibrancyHUDPanel base and the rationale for our
// own panels).

import AppKit

// MARK: - Hyper which-key HUD (held-Caps cheat-sheet, as a keyboard)

/// The held-Caps "which-key" HUD: a dark vibrancy card that draws a real macOS
/// keyboard with every live Hyper (⌘⌥⌃) shortcut lit up ON its physical key --
/// each showing the action's glyph + a short label. You POINT instead of READ,
/// so spatial memory finds the key. Chord PREFIXES (press-then-a-follow-key) are
/// tinted amber with a trailing "…"; unbound keys sit dim for spatial context.
/// CapsHyperTap shows it after a short hold and tears it down on key-press or
/// release. Styled to match WindowModeHUDPanel / ChordHintPanel: non-activating
/// and never steals focus -- but, unlike them, NOT mouse-transparent: a lit key
/// answers to the pointer (hover for details, CLICK to run it), so the board is
/// a launcher as well as a cheat-sheet. The panel stays non-activating through
/// the click, so the user's frontmost window keeps focus and a window action
/// still targets what they were looking at.
@MainActor
final class HyperHintPanel {
    struct Row {
        let key: String; let label: String; let chord: Bool; let icon: String?; let desc: String?
        /// The registry.runAction pair a click on this key fires.
        let featureId: String; let actionId: String
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 260))
    /// Called with the row whose key the user CLICKED (the mouse twin of
    /// pressing that key). The owner decides what that means -- run the action,
    /// or arm the chord for a prefix key.
    private let onActivate: ((Row) -> Void)?

    // Bottom line: the dim caption by default; a hovered key's full name + what
    // it does while the pointer is over it (the on-key label truncates, so this
    // is where the full text lives).
    private let hintLine = FixedHintField(labelWithString: "")
    private var defaultCaption = ""

    static let unit: CGFloat = 46   // one key-unit (a letter key's width/height)
    static let keyH: CGFloat = 46
    static let gap:  CGFloat = 6

    /// One physical key slot. `name` is the canonical key name a Hyper binding
    /// would use (matched against the legend, lowercased); nil = a modifier/
    /// decorative key that can never be a Hyper key. `face` is the glyph drawn on
    /// the cap; `u` its width in key-units.
    private struct K {
        let face: String; let name: String?; let u: CGFloat
        init(_ face: String, _ name: String?, _ u: CGFloat = 1) { self.face = face; self.name = name; self.u = u }
    }

    // A compact ANSI-ish board: number row + three letter rows + a space row.
    // Only the keys that can carry a Hyper binding get a `name`; modifiers don't.
    private let board: [[K]] = [
        [K("`","`"),K("1","1"),K("2","2"),K("3","3"),K("4","4"),K("5","5"),K("6","6"),
         K("7","7"),K("8","8"),K("9","9"),K("0","0"),K("-","-"),K("=","="),K("⌫","delete",1.6)],
        [K("⇥","tab",1.5),K("Q","q"),K("W","w"),K("E","e"),K("R","r"),K("T","t"),K("Y","y"),
         K("U","u"),K("I","i"),K("O","o"),K("P","p"),K("[","["),K("]","]"),K("\\","\\",1.1)],
        [K("⇪",nil,1.8),K("A","a"),K("S","s"),K("D","d"),K("F","f"),K("G","g"),K("H","h"),
         K("J","j"),K("K","k"),K("L","l"),K(";",";"),K("'","'"),K("⏎","return",1.9)],
        [K("⇧",nil,2.3),K("Z","z"),K("X","x"),K("C","c"),K("V","v"),K("B","b"),K("N","n"),
         K("M","m"),K(",",","),K(".","."),K("/","/"),K("⇧",nil,2.3)],
        [K("fn",nil,1.1),K("⌃",nil,1.1),K("⌥",nil,1.1),K("⌘",nil,1.3),K("space","space",6.4),
         K("⌘",nil,1.3),K("⌥",nil,1.1)],
    ]

    init(rows: [Row], onActivate: ((Row) -> Void)? = nil) {
        self.onActivate = onActivate
        var byKey: [String: Row] = [:]
        for r in rows { byKey[r.key.lowercased()] = r }

        // This panel (unlike its sibling HUDs) accepts mouse events so a key can
        // reveal its full name on hover and RUN on click. It stays
        // non-activating, so pointing at it never steals keyboard focus and the
        // held-Caps tap keeps firing.
        hud.ignoresMouseEvents = false

        defaultCaption = Strings.t("hyper.caption",
            default: "press or click a key  ·  amber … = chord  ·  hover for details  ·  release Caps to dismiss")
        hintLine.font = .systemFont(ofSize: 10.5)
        hintLine.textColor = .tertiaryLabelColor
        hintLine.alignment = .center
        hintLine.lineBreakMode = .byTruncatingTail
        hintLine.maximumNumberOfLines = 1
        hintLine.stringValue = defaultCaption

        let stack = hud.stack
        stack.alignment = .centerX
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)

        let board = boardView(byKey)
        stack.addArrangedSubview(titleLabel("⌃⌥⌘  Hyper"))
        stack.addArrangedSubview(board)
        stack.addArrangedSubview(hintLine)
        // Fully FIX the hint line's frame -- width == the keyboard, height a
        // constant -- and let it yield on both axes. Then hovering a key only
        // changes the TEXT (it truncates if long); the content's fitting size is
        // invariant, so AppKit never grows the window to fit, and it can't drift
        // or shake as the pointer moves key to key (the reported bug: the window
        // was auto-resizing to a long description, anchored top-left).
        hintLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLine.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hintLine.widthAnchor.constraint(equalTo: board.widthAnchor).isActive = true
        hintLine.heightAnchor.constraint(equalToConstant: 15).isActive = true

        // lockSize: freeze the frame after sizing so the hover hint (which
        // mutates the bottom line) can never grow, shift, or shake the card.
        hud.present(minWidth: 560, lockSize: true)
    }

    func close() { hud.orderOut(nil) }

    /// Update the bottom line to a hovered key's descriptor, or restore the
    /// default caption when the pointer leaves (nil).
    private func showHint(_ text: String?) {
        if let text {
            hintLine.stringValue = text
            hintLine.textColor = .labelColor
        } else {
            hintLine.stringValue = defaultCaption
            hintLine.textColor = .tertiaryLabelColor
        }
    }

    // MARK: - Pieces

    private func titleLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 2.0])
        f.alignment = .center
        return f
    }

    /// The keyboard: the letter/number rows stacked vertically, with the arrow
    /// cluster sitting to their right, bottom-aligned (as on a real board).
    private func boardView(_ byKey: [String: Row]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = Self.gap
        for r in board {
            let line = NSStackView()
            line.orientation = .horizontal
            line.spacing = Self.gap
            for k in r { line.addArrangedSubview(keyView(k, byKey)) }
            rows.addArrangedSubview(line)
        }

        let h = NSStackView()
        h.orientation = .horizontal
        h.alignment = .bottom
        h.spacing = 16
        h.addArrangedSubview(rows)
        h.addArrangedSubview(arrowCluster(byKey))
        return h
    }

    /// The inverted-T arrow cluster; all four arrows are Window-Snap halves.
    private func arrowCluster(_ byKey: [String: Row]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = Self.gap
        let top = NSStackView(); top.spacing = Self.gap
        top.addArrangedSubview(keyView(K("↑", "up"), byKey))
        let bottom = NSStackView(); bottom.spacing = Self.gap
        bottom.addArrangedSubview(keyView(K("←", "left"), byKey))
        bottom.addArrangedSubview(keyView(K("↓", "down"), byKey))
        bottom.addArrangedSubview(keyView(K("→", "right"), byKey))
        col.addArrangedSubview(top)
        col.addArrangedSubview(bottom)
        return col
    }

    private func keyView(_ k: K, _ byKey: [String: Row]) -> NSView {
        let w = Self.unit * k.u + Self.gap * (k.u - 1)   // wide keys span units + the gaps between them
        let v = HyperKeyView(width: w)
        if let name = k.name, let row = byKey[name] {
            v.setLit(face: k.face, symbol: row.icon, label: row.label, chord: row.chord)
            v.hint = hintText(face: k.face, row: row)
            v.onHover = { [weak self] in self?.showHint($0) }
            if let onActivate { v.onClick = { onActivate(row) } }
        } else {
            v.setDim(face: k.face)
        }
        return v
    }

    /// The full one-line descriptor a key shows on hover: the whole shortcut,
    /// the action's name, and what it does (label truncates on the cap; here it's
    /// spelled out).
    private func hintText(face: String, row: Row) -> String {
        let readable: String
        switch face {
        case "space": readable = "Space"
        case "⏎":     readable = "Return"
        default:      readable = face
        }
        var s = "⌃⌥⌘ " + readable + (row.chord ? " then a key" : "") + "   " + row.label
        if let d = row.desc, !d.isEmpty { s += "  —  " + d }
        return s
    }
}

/// A label whose intrinsic size is FIXED regardless of its string. A normal
/// NSTextField reports an intrinsic WIDTH equal to its full text even when it
/// truncates on screen -- so swapping the hover hint to a longer description
/// re-invalidated layout and grew/shook the HUD. Reporting no intrinsic width
/// (the ==keyboard constraint sets it) and a constant height means a text change
/// triggers zero layout, so the card can't move.
@MainActor
private final class FixedHintField: NSTextField {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 15) }
}

/// One key cap. Dim = a plain gray keycap with its face centered. Lit = an
/// accent (or amber, for a chord prefix) cap with the key face tucked top-left,
/// the action glyph centered, and a truncated label along the bottom.
///
/// A lit cap is also a BUTTON: hover lights its border, press darkens its fill,
/// and releasing inside fires `onClick` (releasing outside cancels, like any
/// AppKit button). Dim caps are inert -- they exist for spatial context only.
/// The border IS the hover affordance; a cursor change is not available here
/// (see updateTrackingAreas).
@MainActor
private final class HyperKeyView: NSView {
    private let faceLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var lit = false
    /// Full descriptor shown in the panel's hint line while hovered.
    var hint: String?
    /// Called with `hint` on mouse-enter and `nil` on exit.
    var onHover: ((String?) -> Void)?
    /// Called when this cap is clicked. nil = not clickable (a dim key).
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var baseBorder: CGColor?
    private var baseFill: CGColor?
    private var pressedFill: CGColor?
    /// True between mouse-down and mouse-up on this cap.
    private var pressing = false

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: HyperHintPanel.keyH))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: HyperHintPanel.keyH).isActive = true

        faceLabel.alignment = .center
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = .white
        nameLabel.font = .systemFont(ofSize: 8.5, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        addSubview(faceLabel); addSubview(glyph); addSubview(nameLabel)
    }
    required init?(coder: NSCoder) { nil }

    func setDim(face: String) {
        lit = false
        baseFill = NSColor.white.withAlphaComponent(0.05).cgColor
        pressedFill = nil
        layer?.backgroundColor = baseFill
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        faceLabel.stringValue = face
        faceLabel.font = .systemFont(ofSize: 13, weight: .regular)
        faceLabel.textColor = .tertiaryLabelColor
        glyph.isHidden = true
        nameLabel.isHidden = true
        needsLayout = true
    }

    func setLit(face: String, symbol: String?, label: String, chord: Bool) {
        lit = true
        let accent: NSColor = chord ? .systemOrange : .controlAccentColor
        baseFill = accent.withAlphaComponent(0.92).cgColor
        // Pressed = the same cap pushed darker, the AppKit button convention.
        pressedFill = (accent.blended(withFraction: 0.32, of: .black) ?? accent)
            .withAlphaComponent(0.95).cgColor
        layer?.backgroundColor = baseFill
        layer?.borderColor = accent.blended(withFraction: 0.35, of: .white)?.cgColor
            ?? accent.cgColor
        baseBorder = layer?.borderColor
        faceLabel.stringValue = face
        faceLabel.font = .systemFont(ofSize: 8.5, weight: .semibold)
        faceLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        if let symbol,
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
            img.isTemplate = true
            glyph.image = img
            glyph.isHidden = false
        } else {
            glyph.isHidden = true
        }
        nameLabel.stringValue = label + (chord ? "…" : "")
        nameLabel.isHidden = false
        needsLayout = true
    }

    // Only lit keys are hoverable; `.activeAlways` so enter/exit fire even though
    // the panel is non-activating.
    //
    // NO POINTING-HAND CURSOR HERE, and that is a HARD CONSTRAINT, not an
    // oversight -- do not "fix" it. This panel is never key and its app is never
    // active, which defeats every cursor mechanism AppKit has. Measured
    // 2026-07-30, both with a real hover (proven by the hint line updating):
    //   - `.cursorUpdate` on the tracking area: NSTrackingArea.h says of
    //     `.activeAlways` verbatim "Not supported for NSTrackingCursorUpdate",
    //     so `cursorUpdate(with:)` is simply never called. The other activity
    //     options (first-responder / key-window / active-app) can never be
    //     satisfied by this window, so there is no working combination.
    //   - `NSCursor.pointingHand.set()` from mouseEntered: overridden within the
    //     frame by the ACTIVE app's cursor -- hovering a cap over a VSCode
    //     editor showed VSCode's I-beam, straight through the panel.
    //     `disableCursorRects()` on our window changes nothing: the cursor is
    //     not ours to set while another app is frontmost.
    // The affordance that DOES work is the border lighting up (below) plus the
    // hint line and the "press or click a key" caption.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t); tracking = nil }
        guard lit else { return }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(hint)
        layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
        layer?.borderColor = baseBorder
    }

    // MARK: - Click

    /// The panel is never key (non-activating, canBecomeKey == false), so without
    /// this the FIRST click on a cap would only be swallowed as an activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onClick != nil }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { super.mouseDown(with: event); return }
        pressing = true
        setPressedLook(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { super.mouseDragged(with: event); return }
        setPressedLook(isInside(event))   // dragging off the cap un-presses it
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { super.mouseUp(with: event); return }
        pressing = false
        setPressedLook(false)
        // Releasing outside the cap cancels -- the standard button escape hatch.
        if isInside(event) { onClick?() }
    }

    private func isInside(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func setPressedLook(_ on: Bool) {
        layer?.backgroundColor = (on ? pressedFill : baseFill) ?? baseFill
    }

    override func layout() {
        super.layout()
        let b = bounds
        if lit {
            // Face top-left; glyph centered-upper; label along the bottom.
            faceLabel.frame = NSRect(x: 4, y: b.height - 14, width: 18, height: 11)
            glyph.frame = NSRect(x: 0, y: b.height * 0.36, width: b.width, height: 18)
            nameLabel.frame = NSRect(x: 2, y: 3, width: b.width - 4, height: 11)
        } else {
            faceLabel.frame = NSRect(x: 0, y: (b.height - 16) / 2, width: b.width, height: 16)
        }
    }
}
