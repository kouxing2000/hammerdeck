// window_fan's CONTRIBUTED native UI (co-located under the feature's swift/, like
// window_deck's DeckWidgetPanel and usage_stats' UsageWidgetPanel): bespoke to this
// feature, driven only through the thin `fan_widget_*` seam in Native+Panels.swift
// -- NOT a shared platform panel. See Panels.swift for the shared FloatingPanel base.
//
// The Window Fan switcher card: a small DRAGGABLE floating panel that lists the
// windows in the fan. A header (title + live count + a round Exit button) sits over a
// vertical list of ROWS -- each row is an EDGE SWATCH (a mini window-glyph with a
// colored bar on the very edge that window exposes: top / bottom / left / right, tinted
// to match its on-screen border), the app icon, and the window title. The focused row
// is highlighted. Clicking a row reports its 1-based index back to Lua, which focuses
// that window; the Exit button leaves the mode.
//
// Like DeckWidgetPanel it is mouse-OPAQUE, non-activating, and never key -- so dragging
// or clicking it never steals focus from a fanned window (the click switches the
// TARGET window, not the widget). The row list is fully rebuilt on setRows as the fan
// gains/loses windows or focus moves.

import AppKit

@MainActor
final class FanWidgetPanel {
    /// One window's row, as it crosses the seam.
    struct Row {
        let color: String      // hex, matches the window's border
        let side: String       // "T" | "B" | "L" | "R" -- the exposed edge
        let title: String
        let bundleID: String   // for the app icon ("" -> generic)
        let focused: Bool
    }

    private let panel: FloatingPanel
    private let card: DraggableCardView
    private let onMove: (Double, Double) -> Void
    private let onSwitch: (Int) -> Void
    private let countLabel = NSTextField(labelWithString: "")
    private let list = NSStackView()
    private var clamp: NSRect

    init(title: String, count: String,
         rows: [Row], topLeft: CGPoint, screen: NSRect,
         onMove: @escaping (Double, Double) -> Void,
         onExit: @escaping () -> Void, onSwitch: @escaping (Int) -> Void) {
        self.onMove = onMove
        self.onSwitch = onSwitch
        self.clamp = screen

        card = DraggableCardView()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            level: .statusBar,
            collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary],
            keyable: false, mouseTransparent: false, hasShadow: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false

        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor =
            NSColor(srgbRed: 0.106, green: 0.106, blue: 0.14, alpha: 0.97).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // --- Header: title + count .... Exit -----------------------------------
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let close = CloseButtonView()
        close.onClick = onExit
        let header = NSStackView(views: [titleLabel, countLabel, spacer, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        // --- Row list ----------------------------------------------------------
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3

        let vstack = NSStackView(views: [header, list])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8
        vstack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11),
            vstack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            header.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            list.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            // A comfortable fixed content width so window titles get real room (the
            // header alone would otherwise size the card and collapse the titles).
            // Fixed, not title-driven, so the draggable card never jumps width as
            // membership / focus changes; long titles still truncate with a tail.
            vstack.widthAnchor.constraint(equalToConstant: 320),
        ])

        panel.contentView = card
        card.onMoved = { [weak self] in self?.reportMove() }
        card.clampOrigin = { [weak self] o in self?.clamped(o) ?? o }

        setRows(rows, count: count)
        place(topLeft: topLeft)
        panel.orderFrontRegardless()
    }

    /// Rebuild the row list (called whenever the fan's membership or focus changes)
    /// and re-fit the card, keeping its TOP-LEFT anchored so it grows downward.
    /// `count` is the pre-localized header count string (Lua owns the plural).
    func setRows(_ rows: [Row], count: String) {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            let row = RowView(index: i + 1, row: r)
            row.onClick = { [weak self] in self?.onSwitch(i + 1) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        countLabel.stringValue = count

        // Re-fit while pinning the top-left corner (AppKit origin is bottom-left,
        // so growing height must drop the origin to keep the top edge fixed).
        card.layoutSubtreeIfNeeded()
        let topY = panel.frame.maxY
        let size = card.fittingSize
        panel.setContentSize(size)
        var f = panel.frame
        f.origin.y = topY - f.height
        panel.setFrame(clampedFrame(f), display: true)
    }

    private func clamped(_ o: NSPoint) -> NSPoint {
        let sz = panel.frame.size
        let minX = clamp.minX, maxX = max(clamp.minX, clamp.maxX - sz.width)
        let minY = clamp.minY, maxY = max(clamp.minY, clamp.maxY - sz.height)
        return NSPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    private func clampedFrame(_ f: NSRect) -> NSRect {
        NSRect(origin: clamped(f.origin), size: f.size)
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

    func close() { panel.orderOut(nil) }
}

// MARK: - Views

/// The card body; drags the (clamped) panel by any empty point on it.
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

/// One window row: edge swatch + app icon + title. The focused row gets a filled
/// background + bold title. A plain click switches to that window.
private final class RowView: NSView {
    var onClick: (() -> Void)?
    private let focused: Bool

    init(index: Int, row: FanWidgetPanel.Row) {
        self.focused = row.focused
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        if row.focused {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
        translatesAutoresizingMaskIntoConstraints = false

        let swatch = EdgeSwatchView(colorHex: row.color, side: row.side)
        let icon = NSImageView()
        icon.image = AppCatalog.icon(forBundleId: row.bundleID)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: row.title.isEmpty ? "—" : row.title)
        title.font = .systemFont(ofSize: 13, weight: row.focused ? .semibold : .regular)
        title.textColor = row.focused ? .white : NSColor.white.withAlphaComponent(0.88)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let hs = NSStackView(views: [swatch, icon, title])
        hs.orientation = .horizontal
        hs.alignment = .centerY
        hs.spacing = 9
        hs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hs)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            hs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hs.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            hs.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var pressed = false
    override func mouseDown(with e: NSEvent) { pressed = true }
    override func mouseUp(with e: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A tiny window-glyph with a thick colored bar on the edge the window exposes
/// (T/B/L/R) -- a spatial cue that echoes the on-screen border. Neutral outline
/// for the window body, tinted bar for the grabbable edge.
private final class EdgeSwatchView: NSView {
    private let color: NSColor
    private let side: String

    init(colorHex: String, side: String) {
        self.color = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let body = bounds.insetBy(dx: 1.5, dy: 1.5)
        // Window body: faint rounded outline.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
        // Exposed edge: a thick colored bar hugging the given side.
        ctx.setFillColor(color.cgColor)
        let t: CGFloat = 4
        let bar: CGRect
        switch side {
        case "T": bar = CGRect(x: body.minX, y: body.maxY - t, width: body.width, height: t)
        case "B": bar = CGRect(x: body.minX, y: body.minY, width: body.width, height: t)
        case "L": bar = CGRect(x: body.minX, y: body.minY, width: t, height: body.height)
        default:  bar = CGRect(x: body.maxX - t, y: body.minY, width: t, height: body.height) // "R"
        }
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.fillPath()
    }
}

/// A small round translucent close button ("×") -- leaves the mode.
private final class CloseButtonView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let x = NSTextField(labelWithString: "\u{2715}")
        x.font = .systemFont(ofSize: 12, weight: .semibold)
        x.textColor = NSColor.white.withAlphaComponent(0.75)
        x.translatesAutoresizingMaskIntoConstraints = false
        addSubview(x)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            x.centerXAnchor.constraint(equalTo: centerXAnchor),
            x.centerYAnchor.constraint(equalTo: centerYAnchor),
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
