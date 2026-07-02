// Panels.swift split: one self-owned native UI surface (see Panels.swift for the
// shared FloatingPanel base and the rationale for our own panels).
//
// The Window Deck control card: a small DRAGGABLE floating panel above the
// click-through scrim (ScrimPanel). Top row: grid glyph, "Window Deck · <name>",
// and a clickable "⌥esc Exit" button. Bottom row: a MINI-MAP switcher -- numbered
// cells laid out to mirror the tiling, each tinted with its window's ring color,
// the hero cell lit; clicking a cell makes that window the hero (grid mode when
// you click the current hero).
//
// Why its own panel and not a label on the scrim: the scrim is mouse-transparent,
// so it can't catch a drag or a click. This card is mouse-OPAQUE, non-activating,
// and never key -- so dragging / clicking it never steals focus from a deck
// window (which would fire a spurious peek). The mini-map click just reports the
// cell index back to Lua, which focuses that window and lets the EXISTING promote
// beat run -- no new promotion or z-order path.

import AppKit

@MainActor
final class DeckWidgetPanel {
    private let panel: FloatingPanel
    private let card: DraggableCardView
    private let onMove: (Double, Double) -> Void
    private let onReorder: (Int, Int) -> Void
    private var clamp: NSRect
    private var cells: [MiniCellView] = []
    private let rearrangeButton: RearrangeButtonView
    private let hintLabel = NSTextField(labelWithString: "")

    init(title: String, hint: String, displayName: String, switchHint: String,
         heroLabel: String, exitLabel: String, rearrangeLabel: String,
         gridCols: Int, heroIndex: Int, cellColors: [String], heroOn: Bool,
         topLeft: CGPoint, screen: NSRect,
         onMove: @escaping (Double, Double) -> Void, onExit: @escaping () -> Void,
         onSwitch: @escaping (Int) -> Void, onToggleHero: @escaping (Bool) -> Void,
         onRearrange: @escaping () -> Void, onReorder: @escaping (Int, Int) -> Void) {
        self.onMove = onMove
        self.onReorder = onReorder
        self.clamp = screen
        rearrangeButton = RearrangeButtonView(label: rearrangeLabel)
        rearrangeButton.onClick = onRearrange
        card = DraggableCardView()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 92),
            level: .statusBar,
            collectionBehavior: [.fullScreenAuxiliary],
            keyable: false, mouseTransparent: false, hasShadow: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor =
            NSColor(srgbRed: 0.106, green: 0.106, blue: 0.14, alpha: 0.96).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let accent = NSColor(srgbRed: 0.878, green: 0.353, blue: 0.302, alpha: 1)
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = accent.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        // --- Top row: glyph + title + name .... spacer .... Exit -------------
        let glyph = GridGlyphView(color: accent)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white
        var titleGroup: [NSView] = [glyph, titleLabel]
        if !displayName.isEmpty {
            let nameLabel = NSTextField(labelWithString: "· " + displayName)
            nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
            nameLabel.textColor = NSColor.white.withAlphaComponent(0.5)
            titleGroup.append(nameLabel)
        }
        let titleStack = NSStackView(views: titleGroup)
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 9

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false

        // Hero toggle: label + a switch. Off = pure grid tiler.
        let heroLabelField = NSTextField(labelWithString: heroLabel)
        heroLabelField.font = .systemFont(ofSize: 13, weight: .semibold)
        heroLabelField.textColor = .white
        let heroToggle = ToggleView(on: heroOn)
        heroToggle.onToggle = onToggleHero
        let heroGroup = NSStackView(views: [heroLabelField, heroToggle])
        heroGroup.orientation = .horizontal
        heroGroup.alignment = .centerY
        heroGroup.spacing = 7

        let exit = ExitButtonView(accent: accent, label: exitLabel)
        exit.onClick = onExit

        let topRow = NSStackView(views: [titleStack, spacer, heroGroup, exit])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14

        // --- Bottom row: mini-map + hint -------------------------------------
        let map = Self.buildMiniMap(gridCols: gridCols, colors: cellColors,
                                    onSwitch: onSwitch, into: &cells)
        hintLabel.stringValue = switchHint
        hintLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        let bottomRow = NSStackView(views: [map, hintLabel, bottomSpacer, rearrangeButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 14

        let vstack = NSStackView(views: [topRow, bottomRow])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 10
        vstack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(bar)
        card.addSubview(vstack)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bar.topAnchor.constraint(equalTo: card.topAnchor),
            bar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 5),
            vstack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 14),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            vstack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            // Both rows fill the card width so the Exit / Rearrange buttons hug
            // the right edge regardless of which row is naturally wider.
            topRow.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: vstack.widthAnchor),
        ])

        panel.contentView = card
        card.onMoved = { [weak self] in self?.reportMove() }
        card.clampOrigin = { [weak self] o in self?.clamped(o) ?? o }
        setHero(heroIndex)

        // Wire mini-map cell drag-and-drop now that self is fully initialized:
        // a floating ghost follows the cursor, the cell under it highlights, and
        // dropping swaps.
        for c in cells {
            c.onDragBegan = { [weak self, weak c] img, p in
                self?.beginCellDrag(from: c?.index ?? 0, image: img, at: p) }
            c.onDragMoved = { [weak self] p in self?.updateCellDrag(at: p) }
            c.onDragEnded = { [weak self, weak c] p in
                guard let c else { return }; self?.finishCellDrag(from: c.index, at: p) }
        }

        card.layoutSubtreeIfNeeded()
        panel.setContentSize(card.fittingSize)
        place(topLeft: topLeft)
        panel.orderFrontRegardless()
    }

    // MARK: - Mini-map cell drag-and-drop (reorder within the widget)

    private var ghostWin: NSWindow?
    private var dragSource: Int?   // 1-based faded source cell
    private var dragActive = false

    /// The cell whose on-screen rect contains screen point `p` (0-based), or nil.
    private func cellIndex(atScreenPoint p: NSPoint) -> Int? {
        for (i, c) in cells.enumerated() {
            let inWindow = c.convert(c.bounds, to: nil)
            if let sr = c.window?.convertToScreen(inWindow), sr.contains(p) { return i }
        }
        return nil
    }

    /// Lift a floating snapshot of the dragged cell into its own window (so it
    /// follows the cursor un-clipped, above everything) and fade the source.
    private func beginCellDrag(from: Int, image: NSImage?, at p: NSPoint) {
        dragActive = true
        dragSource = from
        NSCursor.closedHand.push()   // popped in cancelCellDrag (drop OR teardown)
        if from >= 1, from <= cells.count { cells[from - 1].alphaValue = 0.25 }
        guard let image else { return }
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: image.size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let iv = NSImageView(image: image)
        iv.frame = NSRect(origin: .zero, size: image.size)
        win.contentView = iv
        ghostWin = win
        moveGhost(to: p)
        win.orderFrontRegardless()
    }

    private func moveGhost(to p: NSPoint) {
        guard let win = ghostWin else { return }
        let s = win.frame.size
        win.setFrameOrigin(NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
    }

    private func updateCellDrag(at p: NSPoint) {
        moveGhost(to: p)
        let t = cellIndex(atScreenPoint: p)
        // Don't draw a drop-target ring on the faded source cell itself.
        for (i, c) in cells.enumerated() { c.setDropTarget(i == t && i + 1 != dragSource) }
    }

    /// Tear down any in-flight cell drag: remove the ghost, pop the cursor,
    /// restore the source cell, clear highlights. Called on drop AND on panel
    /// teardown (close) so a deck exit mid-drag can't strand a ghost / cursor.
    private func cancelCellDrag() {
        guard dragActive else { return }
        dragActive = false
        NSCursor.pop()
        ghostWin?.orderOut(nil); ghostWin = nil
        if let s = dragSource, s >= 1, s <= cells.count { cells[s - 1].alphaValue = 1 }
        dragSource = nil
        for c in cells { c.setDropTarget(false) }
    }

    private func finishCellDrag(from: Int, at p: NSPoint) {
        let to = cellIndex(atScreenPoint: p)
        cancelCellDrag()
        if let to, to + 1 != from { onReorder(from, to + 1) }
    }

    /// Build a `gridCols`-wide, row-major grid of numbered/colored cells.
    private static func buildMiniMap(gridCols: Int, colors: [String],
                                     onSwitch: @escaping (Int) -> Void,
                                     into cells: inout [MiniCellView]) -> NSView {
        let cols = max(1, gridCols)
        var rows: [NSStackView] = []
        var row: [NSView] = []
        for (i, hex) in colors.enumerated() {
            let cell = MiniCellView(number: i + 1, index: i + 1, colorHex: hex)
            cell.onClick = { onSwitch(i + 1) }   // 1-based, matches Lua order
            cells.append(cell)
            row.append(cell)
            if row.count == cols {
                let hs = NSStackView(views: row); hs.orientation = .horizontal; hs.spacing = 4
                rows.append(hs); row = []
            }
        }
        if !row.isEmpty {
            let hs = NSStackView(views: row); hs.orientation = .horizontal; hs.spacing = 4
            rows.append(hs)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        return grid
    }

    /// Light the cell for the 1-based hero index (0 = grid mode, none lit).
    func setHero(_ index: Int) {
        for (i, c) in cells.enumerated() { c.setHero(i + 1 == index) }
    }

    /// Enable the Rearrange button only when a window is off its grid slot.
    func setDirty(_ dirty: Bool) { rearrangeButton.setEnabled(dirty) }

    /// Recolor the mini-map cells (row-major) after a drag-swap rearranges which
    /// window sits in which slot.
    func setCellColors(_ colors: [String]) {
        for (i, c) in cells.enumerated() where i < colors.count { c.setColor(colors[i]) }
    }

    /// Update the mini-map hint (the deck swaps it with the Hero mode).
    func setSwitchHint(_ text: String) { hintLabel.stringValue = text }

    private func clamped(_ o: NSPoint) -> NSPoint {
        let sz = panel.frame.size
        let minX = clamp.minX, maxX = max(clamp.minX, clamp.maxX - sz.width)
        let minY = clamp.minY, maxY = max(clamp.minY, clamp.maxY - sz.height)
        return NSPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    private func place(topLeft: CGPoint) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let raw = NSPoint(x: topLeft.x, y: primaryMaxY - (topLeft.y + panel.frame.height))
        panel.setFrameOrigin(clamped(raw))
    }

    private func reportMove() {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        onMove(Double(panel.frame.minX), Double(primaryMaxY - panel.frame.maxY))
    }

    func reanchor(topLeft: CGPoint, screen: NSRect) {
        clamp = screen
        place(topLeft: topLeft)
    }

    func hide() { panel.orderOut(nil) }
    func show() { panel.orderFrontRegardless() }
    func close() { cancelCellDrag(); panel.orderOut(nil) }
}

/// The card body; drags the panel (clamped) by any empty point on it.
private final class DraggableCardView: NSView {
    var onMoved: (() -> Void)?
    var clampOrigin: ((NSPoint) -> NSPoint)?
    private var mouseStart: NSPoint?
    private var winStart: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        winStart = window?.frame.origin
    }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window, let ms = mouseStart, let ws = winStart else { return }
        let now = NSEvent.mouseLocation
        var o = NSPoint(x: ws.x + (now.x - ms.x), y: ws.y + (now.y - ms.y))
        if let clampOrigin { o = clampOrigin(o) }
        w.setFrameOrigin(o)
    }
    override func mouseUp(with e: NSEvent) {
        let moved = mouseStart != nil
        mouseStart = nil; winStart = nil
        if moved { onMoved?() }
    }
}

/// A mini-map cell: a numbered, ring-colored, clickable square. Hero = filled;
/// otherwise a faint tint with a colored outline.
private final class MiniCellView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: ((NSImage?, NSPoint) -> Void)?   // threshold crossed: (ghost image, point)
    var onDragMoved: ((NSPoint) -> Void)?   // during a drag: global cursor point
    var onDragEnded: ((NSPoint) -> Void)?   // on mouse-up after a drag
    let index: Int                          // 1-based cell index
    private var color: NSColor
    private let label = NSTextField(labelWithString: "")
    private var pressed = false
    private var dragging = false
    private var downPoint: NSPoint?
    private var hero = false

    init(number: Int, index: Int, colorHex: String) {
        self.index = index
        color = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = String(number)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setHero(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHero(_ on: Bool) {
        hero = on
        layer?.backgroundColor = on ? color.cgColor
                                    : color.withAlphaComponent(0.22).cgColor
        layer?.borderColor = on ? NSColor.white.withAlphaComponent(0.85).cgColor
                                : color.withAlphaComponent(0.7).cgColor
        label.textColor = .white
    }

    /// Recolor (after a swap re-homes windows); keeps the hero / drop styling.
    func setColor(_ hex: String) {
        color = NSColor(hexRGB: hex) ?? .controlAccentColor
        setHero(hero)
    }

    /// Highlight this cell as the drop target during a mini-map drag.
    func setDropTarget(_ on: Bool) {
        if on {
            layer?.borderColor = NSColor.white.cgColor
            layer?.borderWidth = 2
        } else {
            layer?.borderWidth = 1
            setHero(hero)   // restore the normal / hero border
        }
    }

    /// A bitmap of the cell's current look -- the floating drag ghost renders it.
    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        pressed = true; dragging = false; downPoint = NSEvent.mouseLocation
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downPoint else { return }
        let now = NSEvent.mouseLocation
        if !dragging && (abs(now.x - d.x) > 4 || abs(now.y - d.y) > 4) {
            dragging = true                       // crossed the threshold: pick up
            onDragBegan?(snapshot(), now)         // panel manages the ghost + cursor
        }
        if dragging { onDragMoved?(now) }
    }
    override func mouseUp(with e: NSEvent) {
        let wasDragging = dragging
        pressed = false; dragging = false; downPoint = nil
        if wasDragging {
            onDragEnded?(NSEvent.mouseLocation)   // a drag: swap on drop
        } else if bounds.contains(convert(e.locationInWindow, from: nil)) {
            onClick?()                            // a plain click: switch hero
        }
    }
}

/// A 2x2 grid of small rounded squares -- the deck's mark.
private final class GridGlyphView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 17, height: 17) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(color.cgColor)
        let s: CGFloat = 7, gap: CGFloat = 3
        for i in 0..<2 {
            for j in 0..<2 {
                let r = CGRect(x: CGFloat(j) * (s + gap), y: CGFloat(i) * (s + gap),
                               width: s, height: s)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            }
        }
        ctx.fillPath()
    }
}

/// The clickable red "⌥esc  Exit" button.
private final class ExitButtonView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false

    init(accent: NSColor, label labelText: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = accent.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let cap = KeyCapView(text: "⌥esc")
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cap)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            cap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cap.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 11),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { pressed = true }
    override func mouseUp(with e: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
}

/// The "Rearrange" button (grid glyph + label) -- re-tiles the deck. Enabled
/// only when a window is off its slot (setEnabled dims + gates the click).
private final class RearrangeButtonView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false
    private var enabled = false

    init(label labelText: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.96, alpha: 0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = GridGlyphView(color: .white)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 11),
        ])
        setEnabled(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(_ on: Bool) { enabled = on; alphaValue = on ? 1 : 0.38 }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { pressed = enabled }
    override func mouseUp(with e: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A macOS-style on/off switch: green pill + white knob when on, gray when off.
/// Own click handling + accepts first mouse (non-key panel).
private final class ToggleView: NSView {
    var onToggle: ((Bool) -> Void)?
    private var isOn: Bool
    private let knob = CALayer()
    private let onColor = NSColor(srgbRed: 0.18, green: 0.75, blue: 0.40, alpha: 1)
    private let offColor = NSColor(white: 0.35, alpha: 1)

    init(on: Bool) {
        isOn = on
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 11
        knob.cornerRadius = 9
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
    override func layout() { super.layout(); apply() }

    private func apply() {
        layer?.backgroundColor = (isOn ? onColor : offColor).cgColor
        let d: CGFloat = 18
        knob.frame = CGRect(x: isOn ? bounds.width - d - 2 : 2, y: 2, width: d, height: d)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {}   // consume, so mouseUp is delivered here
    override func mouseUp(with e: NSEvent) {
        guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        CATransaction.begin(); CATransaction.setDisableActions(true); apply(); CATransaction.commit()
        onToggle?(isOn)
    }
}

/// A faint rounded key-cap chip (e.g. "⌥esc").
private final class KeyCapView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: centerXAnchor),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: l.widthAnchor, constant: 14),
            heightAnchor.constraint(equalToConstant: 21),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
