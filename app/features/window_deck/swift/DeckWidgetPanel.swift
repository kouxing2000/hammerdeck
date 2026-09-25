// window_deck's CONTRIBUTED native UI (co-located under the feature's swift/, like
// usage_stats' UsageWidgetPanel): bespoke to this feature, driven only through the
// thin `deck_widget_*` seam in Native+Panels.swift -- NOT a shared platform panel.
// See Panels.swift for the shared FloatingPanel base and the rationale for our own panels.
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
    // Kept so the mini-map can be REBUILT in place when the deck reflows to a new
    // window count (see setCells): the row that hosts it, the current map view to
    // swap out, the column count to compare against, and the click handler to
    // re-attach to the fresh cells. Defaults so `init` can touch `self` (the
    // buildMiniMap call below writes into `cells`) before assigning them.
    private var bottomRow = NSStackView()
    private var mapView: NSView = NSView()
    private var gridCols = 2
    private var onSwitch: (Int) -> Void = { _ in }
    private var heroIndex = 0   // last lit cell, so a rebuild can re-light it
    /// HUDScale factor of the deck's screen, fixed at show: every explicit size
    /// below (fonts, cells, insets, buttons) is multiplied by it.
    private let s: CGFloat

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
        let s = HUDScale.factor(forRect: screen)
        self.s = s
        rearrangeButton = RearrangeButtonView(label: rearrangeLabel, scale: s)
        rearrangeButton.onClick = onRearrange
        card = DraggableCardView()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300 * s, height: 92 * s),
            level: .statusBar,
            collectionBehavior: [.fullScreenAuxiliary],
            keyable: false, mouseTransparent: false, hasShadow: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false

        card.wantsLayer = true
        card.layer?.cornerRadius = 14 * s
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
        let glyph = GridGlyphView(color: accent, scale: s)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17 * s, weight: .bold)
        titleLabel.textColor = .white
        var titleGroup: [NSView] = [glyph, titleLabel]
        if !displayName.isEmpty {
            let nameLabel = NSTextField(labelWithString: "· " + displayName)
            nameLabel.font = .systemFont(ofSize: 13 * s, weight: .regular)
            nameLabel.textColor = NSColor.white.withAlphaComponent(0.5)
            titleGroup.append(nameLabel)
        }
        let titleStack = NSStackView(views: titleGroup)
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 9 * s

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false

        // Hero toggle: label + a switch. Off = pure grid tiler.
        let heroLabelField = NSTextField(labelWithString: heroLabel)
        heroLabelField.font = .systemFont(ofSize: 13 * s, weight: .semibold)
        heroLabelField.textColor = .white
        let heroToggle = ToggleView(on: heroOn, scale: s)
        heroToggle.onToggle = onToggleHero
        let heroGroup = NSStackView(views: [heroLabelField, heroToggle])
        heroGroup.orientation = .horizontal
        heroGroup.alignment = .centerY
        heroGroup.spacing = 7 * s

        let exit = ExitButtonView(accent: accent, label: exitLabel, scale: s)
        exit.onClick = onExit

        let topRow = NSStackView(views: [titleStack, spacer, heroGroup, exit])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14 * s

        // --- Bottom row: mini-map + hint -------------------------------------
        self.gridCols = max(1, gridCols)
        self.onSwitch = onSwitch
        let map = Self.buildMiniMap(gridCols: gridCols, colors: cellColors, scale: s,
                                    onSwitch: onSwitch, into: &cells)
        mapView = map
        hintLabel.stringValue = switchHint
        hintLabel.font = .systemFont(ofSize: 12 * s, weight: .regular)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomRow = NSStackView(views: [map, hintLabel, bottomSpacer, rearrangeButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 14 * s

        let vstack = NSStackView(views: [topRow, bottomRow])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 10 * s
        vstack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(bar)
        card.addSubview(vstack)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            bar.topAnchor.constraint(equalTo: card.topAnchor),
            bar.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 5 * s),
            vstack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 14 * s),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14 * s),
            vstack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11 * s),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12 * s),
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
        wireCellDrags()

        card.layoutSubtreeIfNeeded()
        panel.setContentSize(card.fittingSize)
        place(topLeft: topLeft)
        panel.orderFrontRegardless()
    }

    // MARK: - Mini-map cell drag-and-drop (reorder within the widget)

    private var ghostWin: NSWindow?
    private var dragSource: Int?   // 1-based faded source cell
    private var dragActive = false

    /// Attach the drag callbacks to the current `cells`. Re-run after a rebuild
    /// (the old views are gone, so their closures went with them).
    private func wireCellDrags() {
        for c in cells {
            c.onDragBegan = { [weak self, weak c] img, p in
                self?.beginCellDrag(from: c?.index ?? 0, image: img, at: p) }
            c.onDragMoved = { [weak self] p in self?.updateCellDrag(at: p) }
            c.onDragEnded = { [weak self, weak c] p in
                guard let c else { return }; self?.finishCellDrag(from: c.index, at: p) }
        }
    }

    /// The cell whose on-screen rect contains screen point `p` (0-based), or nil.
    /// Dead cells are skipped -- a swap with a closed window means nothing, and
    /// the cell is about to disappear in the next reflow.
    private func cellIndex(atScreenPoint p: NSPoint) -> Int? {
        for (i, c) in cells.enumerated() where !c.isDead {
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
    private static func buildMiniMap(gridCols: Int, colors: [String], scale s: CGFloat,
                                     onSwitch: @escaping (Int) -> Void,
                                     into cells: inout [MiniCellView]) -> NSView {
        let cols = max(1, gridCols)
        var rows: [NSStackView] = []
        var row: [NSView] = []
        for (i, hex) in colors.enumerated() {
            let cell = MiniCellView(number: i + 1, index: i + 1, colorHex: hex, scale: s)
            cell.onClick = { onSwitch(i + 1) }   // 1-based, matches Lua order
            cells.append(cell)
            row.append(cell)
            if row.count == cols {
                let hs = NSStackView(views: row); hs.orientation = .horizontal; hs.spacing = 4 * s
                rows.append(hs); row = []
            }
        }
        if !row.isEmpty {
            let hs = NSStackView(views: row); hs.orientation = .horizontal; hs.spacing = 4 * s
            rows.append(hs)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4 * s
        return grid
    }

    /// Light the cell for the 1-based hero index (0 = grid mode, none lit).
    func setHero(_ index: Int) {
        heroIndex = index   // re-applied after a rebuild: fresh cells start unlit
        for (i, c) in cells.enumerated() { c.setHero(i + 1 == index) }
    }

    /// Enable the Rearrange button only when a window is off its grid slot.
    func setDirty(_ dirty: Bool) { rearrangeButton.setEnabled(dirty) }

    /// Sync the mini-map cells (row-major): recolor after a drag-swap, mark the
    /// cells whose window has CLOSED as dead, and -- when `cols` is supplied and
    /// the geometry actually changed -- rebuild the map at a new cell count (the
    /// deck reflowed after a close). Only a reflow changes the cell count and it
    /// always supplies `cols`, so `cols: nil` never resizes: that is what keeps
    /// the per-render dead-marking from rebuilding the view on every focus event.
    /// The COUNT is checked as well as the column width, because a reflow can
    /// drop a whole row at the same width (9 windows in a 3x3 -> 6 in a 3x2).
    func setCells(_ colors: [String], dead: [Bool], cols: Int?) {
        if let cols {
            let want = max(1, cols)
            if want != gridCols || colors.count != cells.count {
                rebuildMap(cols: want, colors: colors)
            } else {
                recolor(colors)
            }
        } else {
            recolor(colors)
        }
        for (i, c) in cells.enumerated() { c.setDead(i < dead.count && dead[i]) }
    }

    private func recolor(_ colors: [String]) {
        for (i, c) in cells.enumerated() where i < colors.count { c.setColor(colors[i]) }
    }

    /// Swap in a freshly built mini-map at a new cell count / column count. The
    /// panel is re-sized to fit and re-pinned by its TOP-left corner: AppKit
    /// origins are bottom-left, so a plain resize would drag the card's visible
    /// top edge down as it shrinks.
    private func rebuildMap(cols: Int, colors: [String]) {
        cancelCellDrag()   // a drag in flight refers to cells about to be freed
        bottomRow.removeArrangedSubview(mapView)
        mapView.removeFromSuperview()
        cells.removeAll()
        let map = Self.buildMiniMap(gridCols: cols, colors: colors, scale: s,
                                    onSwitch: onSwitch, into: &cells)
        bottomRow.insertArrangedSubview(map, at: 0)
        mapView = map
        gridCols = cols
        wireCellDrags()
        setHero(heroIndex)   // fresh cells start unlit -- put the hero's back
        let top = panel.frame.maxY
        card.layoutSubtreeIfNeeded()
        panel.setContentSize(card.fittingSize)
        panel.setFrameOrigin(clamped(NSPoint(x: panel.frame.minX,
                                             y: top - panel.frame.height)))
        reportMove()   // clamping may have nudged it -- keep Lua's saved offset true
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
    private(set) var isDead = false
    private var dashLayer: CAShapeLayer?   // the dead cell's dashed outline
    private let scale: CGFloat

    init(number: Int, index: Int, colorHex: String, scale: CGFloat) {
        self.index = index
        self.scale = scale
        color = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5 * scale
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = String(number)
        label.font = .systemFont(ofSize: 13 * scale, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38 * scale),
            heightAnchor.constraint(equalToConstant: 26 * scale),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setHero(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setHero(_ on: Bool) {
        hero = on
        guard !isDead else { return }   // a dead cell keeps its hollow look
        layer?.backgroundColor = on ? color.cgColor
                                    : color.withAlphaComponent(0.22).cgColor
        layer?.borderColor = on ? NSColor.white.withAlphaComponent(0.85).cgColor
                                : color.withAlphaComponent(0.7).cgColor
        label.textColor = .white
    }

    /// This cell's window has CLOSED: draw it as an empty slot -- no fill, a
    /// DASHED outline in the window's own color (so you can still tell which one
    /// went) and a dimmed number -- and make it inert (no click, no drag; the
    /// panel's hit-test skips it too). Dashes need a shape layer: CALayer's own
    /// border is solid-only. Same idiom as the hero's dashed home-slot ghost.
    func setDead(_ on: Bool) {
        guard isDead != on else { return }
        isDead = on
        if on {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            let s = CAShapeLayer()
            s.fillColor = nil
            s.strokeColor = color.withAlphaComponent(0.35).cgColor
            s.lineWidth = 1
            s.lineDashPattern = [NSNumber(value: Double(3 * scale)), NSNumber(value: Double(2 * scale))]
            // Retina + no implicit animation, matching OutlinePanel's dashed
            // ghost: a manually added sublayer defaults to 1x (blurry dashes) and
            // has implicit actions ON, which would animate the outline in from
            // an empty path on creation and again on every layout pass.
            s.contentsScale = window?.backingScaleFactor ?? 2
            s.actions = ["path": NSNull(), "frame": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(s)
            dashLayer = s
            label.textColor = NSColor.white.withAlphaComponent(0.3)
            updateDashPath()
        } else {
            dashLayer?.removeFromSuperlayer()
            dashLayer = nil
            layer?.borderWidth = 1
            setHero(hero)   // restores fill, border and label color
        }
    }

    override func layout() {
        super.layout()
        updateDashPath()
    }

    private func updateDashPath() {
        guard let s = dashLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.contentsScale = window?.backingScaleFactor ?? s.contentsScale
        s.frame = bounds
        s.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                        cornerWidth: 5 * scale, cornerHeight: 5 * scale, transform: nil)
        CATransaction.commit()
    }

    /// Recolor (after a swap re-homes windows); keeps the hero / dead / drop styling.
    func setColor(_ hex: String) {
        color = NSColor(hexRGB: hex) ?? .controlAccentColor
        if isDead { dashLayer?.strokeColor = color.withAlphaComponent(0.35).cgColor; return }
        setHero(hero)
    }

    /// Highlight this cell as the drop target during a mini-map drag.
    func setDropTarget(_ on: Bool) {
        guard !isDead else { return }
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
        guard !isDead else { return }   // inert: nothing to focus, nothing to swap
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
        // Reset the state and END any in-flight drag FIRST, then gate only the
        // click. Returning early on `isDead` here would strand a cell that died
        // MID-DRAG (a background close repaints the mini-map): onDragEnded would
        // never fire, so cancelCellDrag never runs and the floating ghost window
        // + pushed cursor leak for the rest of the session. A dead cell is a
        // harmless drop TARGET anyway -- cellIndex(atScreenPoint:) skips it.
        let wasDragging = dragging
        pressed = false; dragging = false; downPoint = nil
        if wasDragging {
            onDragEnded?(NSEvent.mouseLocation)   // a drag: swap on drop
        } else if !isDead, bounds.contains(convert(e.locationInWindow, from: nil)) {
            onClick?()                            // a plain click: switch hero
        }
    }
}

/// A 2x2 grid of small rounded squares -- the deck's mark.
private final class GridGlyphView: NSView {
    private let color: NSColor
    private let scale: CGFloat
    init(color: NSColor, scale: CGFloat) {
        self.color = color; self.scale = scale
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 17 * scale, height: 17 * scale) }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(color.cgColor)
        let s: CGFloat = 7 * scale, gap: CGFloat = 3 * scale
        for i in 0..<2 {
            for j in 0..<2 {
                let r = CGRect(x: CGFloat(j) * (s + gap), y: CGFloat(i) * (s + gap),
                               width: s, height: s)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.6 * scale, cornerHeight: 1.6 * scale, transform: nil))
            }
        }
        ctx.fillPath()
    }
}

/// The clickable red "⌥esc  Exit" button.
private final class ExitButtonView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false

    init(accent: NSColor, label labelText: String, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8 * scale
        layer?.backgroundColor = accent.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let cap = KeyCapView(text: "⌥esc", scale: scale)
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cap)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30 * scale),
            cap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 * scale),
            cap.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cap.trailingAnchor, constant: 8 * scale),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 11 * scale),
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

    init(label labelText: String, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8 * scale
        layer?.backgroundColor = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.96, alpha: 0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let glyph = GridGlyphView(color: .white, scale: scale)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 14 * scale, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30 * scale),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11 * scale),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8 * scale),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 11 * scale),
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
    private let scale: CGFloat

    init(on: Bool, scale: CGFloat) {
        isOn = on
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 11 * scale
        knob.cornerRadius = 9 * scale
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 38 * scale),
            heightAnchor.constraint(equalToConstant: 22 * scale),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 38 * scale, height: 22 * scale) }
    override func layout() { super.layout(); apply() }

    private func apply() {
        layer?.backgroundColor = (isOn ? onColor : offColor).cgColor
        let d: CGFloat = 18 * scale, m: CGFloat = 2 * scale
        knob.frame = CGRect(x: isOn ? bounds.width - d - m : m, y: m, width: d, height: d)
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
    init(text: String, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5 * scale
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12 * scale, weight: .medium)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: centerXAnchor),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalTo: l.widthAnchor, constant: 14 * scale),
            heightAnchor.constraint(equalToConstant: 21 * scale),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
