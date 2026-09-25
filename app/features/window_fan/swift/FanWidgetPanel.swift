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
//
// It is also RESIZABLE, by the grip in its bottom-right corner, and the size persists
// alongside the position. Hand-rolled: the panel is `.borderless`, which has no system
// resize edge at all. Dragging the grip pins the card's size on BOTH axes -- width to
// give long window titles room, height to show more rows than the auto fit chose -- and
// from then on the card no longer grows and shrinks as windows join and leave the fan.
// That is the deliberate trade, not an oversight: a card the user has sized is a card
// that should stay where and how they put it. Double-click the grip to hand both axes
// back to the auto fit.

import AppKit

@MainActor
final class FanWidgetPanel {
    /// One window's row, as it crosses the seam.
    struct Row {
        let color: String      // hex, matches the window's border
        /// "T" | "B" | "L" | "R" -- the exposed edge; "" in LABEL MODE, where no
        /// window was moved so no edge is guaranteed and the swatch is a plain chip.
        let side: String
        let title: String
        let bundleID: String   // for the app icon ("" -> generic)
        let focused: Bool
    }

    private let panel: FloatingPanel
    private let card: DraggableCardView
    private let onMove: (Double, Double) -> Void
    /// Reports the card's outer size after a resize drag, for the caller to persist.
    /// `(0, 0)` means "back to the auto fit" -- the same state a card that was never
    /// resized is in, so restoring it needs no third value.
    private let onResize: (Double, Double) -> Void
    private let onSwitch: (Int) -> Void
    private let countLabel = NSTextField(labelWithString: "")
    private let list = FlippedStackView()
    /// The row list SCROLLS. Without this the card grew unbounded with the window
    /// count, and once it was taller than the screen `clamped()` pinned its origin to
    /// the screen bottom so it grew UPWARD -- carrying the header, and with it the
    /// Exit button, off the top edge. Exit became unreachable exactly when the list
    /// was longest. It went unnoticed while the fan's capacity gate kept the row count
    /// to single digits; LABEL MODE has no such limit by design, so the bound has to
    /// live here.
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    /// The content column's width. A constraint rather than a literal so the resize
    /// grip has something to drive; `defaultContentWidth` until the user drags.
    private var contentWidth: NSLayoutConstraint!
    /// Height of everything in the card that is NOT the row list, MEASURED once from
    /// the live view tree rather than hardcoded. An earlier version carried a literal
    /// `10 + 20 + 8 + 11`, which silently goes stale the moment an inset or the header
    /// changes -- and no test could catch that, because a formula that subtracts its
    /// own constant validates against itself for any value of it.
    private var chromeHeight: CGFloat?
    /// The horizontal twin: the card's width minus the content column, i.e. the side
    /// insets. Measured the same way and for the same reason -- it is what converts
    /// the OUTER size the user drags (and the caller persists) into the inner column.
    private var chromeWidth: CGFloat?
    /// The outer card size the user dragged to, or nil while the card still auto-fits
    /// its rows. Set on every resize drag, cleared by a double-click on the grip.
    private var userSize: NSSize?
    private var resizeStart: (mouse: NSPoint, frame: NSRect)?
    /// Whether the drag in progress actually moved. A bare CLICK on the grip must not
    /// pin the size: it would silently end the auto fit with nothing to show for it.
    private var resizeMoved = false
    private var clamp: NSRect
    /// HUDScale factor of the fan's screen, fixed at show. It sizes the CONTENT
    /// (fonts, rows, insets), the auto-fit width and the size floors; it never
    /// multiplies `userSize`, so a card the user dragged keeps the size they gave
    /// it unless that is below the (scaled) floor.
    private let s: CGFloat

    init(title: String, count: String,
         rows: [Row], topLeft: CGPoint, screen: NSRect,
         size: NSSize?, resizeTip: String,
         onMove: @escaping (Double, Double) -> Void,
         onResize: @escaping (Double, Double) -> Void,
         onExit: @escaping () -> Void, onSwitch: @escaping (Int) -> Void) {
        self.onMove = onMove
        self.onResize = onResize
        self.onSwitch = onSwitch
        self.userSize = size
        self.clamp = screen
        let s = HUDScale.factor(forRect: screen)
        self.s = s

        card = DraggableCardView()
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240 * s, height: 120 * s),
            level: .statusBar,
            collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary],
            keyable: false, mouseTransparent: false, hasShadow: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Without this, the grip's tooltip never appears: AppKit withholds tooltips
        // while the owning app is inactive, and this app is ALWAYS inactive while a fan
        // is on -- the frontmost app is whichever window the user is working in, by
        // design. The property is the documented opt-out, and the only affordance that
        // survives here (see the note on ResizeGripView: every cursor mechanism is
        // defeated on a never-key panel, measured, so the tooltip is not a nice-to-have
        // -- it is where the double-click-to-reset gesture is written down at all).
        panel.allowsToolTipsWhenApplicationIsInactive = true

        card.wantsLayer = true
        card.layer?.cornerRadius = 14 * s
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor =
            NSColor(srgbRed: 0.106, green: 0.106, blue: 0.14, alpha: 0.97).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        // --- Header: title + count .... Exit -----------------------------------
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14 * s, weight: .bold)
        titleLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 12 * s, weight: .regular)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let close = CloseButtonView(scale: s)
        close.onClick = onExit
        let header = NSStackView(views: [titleLabel, countLabel, spacer, close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7 * s

        // --- Row list (inside a scroll view; see `scroll`) ----------------------
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 3 * s
        list.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let vstack = NSStackView(views: [header, scroll])
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8 * s
        vstack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(vstack)
        // Sized in setRows to the content height, capped so the card always fits the
        // screen. Placeholder value only.
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 100)
        contentWidth = vstack.widthAnchor.constraint(equalToConstant: Self.defaultContentWidth * s)
        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12 * s),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11 * s),
            vstack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10 * s),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11 * s),
            header.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            scrollHeight,
            // The document view tracks the CLIP view's width, not the scroll view's.
            // With legacy scrollers (a mouse attached, or "Show scroll bars: Always")
            // the clip is ~17pt narrower than the scroll view -- measured 303 vs 320 --
            // so anchoring to the outer width pushes the right edge of every row into
            // a region no scroller can reach, since there is no horizontal scroller.
            // Titles would lose exactly the width the card is sized to give them.
            // Invisible with overlay scrollers, which cost no width.
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // A comfortable content width so window titles get real room (the header
            // alone would otherwise size the card and collapse the titles). Never
            // title-driven, so the draggable card does not jump width as membership /
            // focus changes; long titles truncate with a tail until the user widens it
            // by the grip below.
            contentWidth,
        ])

        // The grip is added AFTER the content, so it is hit-tested before the row list
        // it overlaps -- a geometric corner test on the card itself would never see the
        // click, because a RowView (or the scroller) claims that point first. The cost
        // of winning that contest is that the corner 14pt of the LAST row switches no
        // window, and with legacy scrollers the very bottom of the scroller track is
        // unreachable: both are a few points at the one spot a resize is reached for.
        let grip = ResizeGripView(scale: s)
        grip.toolTip = resizeTip.isEmpty ? nil : resizeTip
        grip.onBegin = { [weak self] in self?.beginResize() }
        grip.onDrag = { [weak self] in self?.dragResize() }
        grip.onEnd = { [weak self] in self?.endResize() }
        grip.onReset = { [weak self] in self?.resetSize() }
        card.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4 * s),
            grip.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4 * s),
        ])

        panel.contentView = card
        card.onMoved = { [weak self] in self?.reportMove() }
        card.clampOrigin = { [weak self] o in self?.clamped(o) ?? o }

        setRows(rows, count: count)
        place(topLeft: topLeft)
        panel.orderFrontRegardless()
    }

    /// The content column's width before the user has resized anything, at
    /// HUDScale 1 (the panel multiplies it by its screen's factor).
    static let defaultContentWidth: CGFloat = 320
    /// Below this the card stops being a list of window titles and starts being a
    /// column of ellipses, so the grip refuses to go further. Both floors are at
    /// HUDScale 1: the clamps below take the factor, since the rows they protect grow.
    static let minCardWidth: CGFloat = 240
    /// A list too short to show one row is useless.
    static let minListHeight: CGFloat = 80
    /// Keeps a full-height card off both screen edges rather than exactly filling it.
    static let screenMargin: CGFloat = 40

    /// The row list's height: its content, but never more than the screen can show
    /// once `chrome` (everything else in the card) is accounted for.
    ///
    /// PURE and `static` so the clamping is testable without a window server. `chrome`
    /// is passed in rather than baked in because the caller MEASURES it from the live
    /// view tree -- that is what makes the bound real instead of a restatement of a
    /// constant. NOTE the floor: on a very short display the floor wins and the card
    /// may exceed the screen, because a list too small to show one row is useless.
    static func listHeight(content: CGFloat, screenHeight: CGFloat,
                           chrome: CGFloat, scale: CGFloat = 1) -> CGFloat {
        min(content, max(minListHeight * scale, screenHeight - chrome - screenMargin))
    }

    /// The same bound, applied to a height the USER dragged to rather than one the
    /// content asked for: their number is honored between the one-row floor and the
    /// identical screen cap. Composed from `listHeight` rather than restating it, so a
    /// dragged card and an auto-fitting one can never disagree about what fits.
    ///
    /// The floor matters twice here: a drag can ask for a NEGATIVE height (pull the
    /// grip up past the header), which `listHeight` would pass straight through.
    static func userListHeight(requested: CGFloat, screenHeight: CGFloat,
                               chrome: CGFloat, scale: CGFloat = 1) -> CGFloat {
        max(minListHeight * scale, listHeight(content: requested, screenHeight: screenHeight,
                                              chrome: chrome, scale: scale))
    }

    /// The card's outer width for a dragged `requested`: at least a readable minimum,
    /// at most the screen less the same margin the height uses. Pure, for the same
    /// reason as the two above -- the clamps are the part worth testing.
    static func cardWidth(requested: CGFloat, screenWidth: CGFloat,
                          scale: CGFloat = 1) -> CGFloat {
        let floor = minCardWidth * scale
        return min(max(requested, floor), max(floor, screenWidth - screenMargin))
    }

    /// Rebuild the row list (called whenever the fan's membership or focus changes)
    /// and re-fit the card, keeping its TOP-LEFT anchored so it grows downward.
    /// `count` is the pre-localized header count string (Lua owns the plural).
    func setRows(_ rows: [Row], count: String) {
        // setRows runs on EVERY focus event and every reconcile tick, so it must not
        // fight the user's own scrolling: remember where they were and put them back.
        // Forcing a scroll here instead would yank a user who scrolled to find a
        // window back to the end within ~2 seconds.
        let wasScrolledTo = scroll.contentView.bounds.origin
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, r) in rows.enumerated() {
            let row = RowView(index: i + 1, row: r, scale: s)
            row.onClick = { [weak self] in self?.onSwitch(i + 1) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        countLabel.stringValue = count

        // Measure the chrome ONCE, from the real tree: with the list collapsed to
        // zero, the card's fitting height IS everything that is not the list.
        if chromeHeight == nil {
            let keep = scrollHeight.constant
            scrollHeight.constant = 0
            card.layoutSubtreeIfNeeded()
            chromeHeight = card.fittingSize.height
            // Measured at the same moment, from the same collapsed tree: whatever the
            // card fits to beyond the content column IS the side chrome.
            chromeWidth = card.fittingSize.width - contentWidth.constant
            scrollHeight.constant = keep
        }
        applySize()
        refit()
        // Restore the user's scroll position (AppKit clamps it if the list shrank).
        // The document view is FLIPPED, so y grows downward and a fresh panel's 0 is
        // the TOP -- with an unflipped NSStackView this same code showed the BOTTOM of
        // the list, hiding row 1 and the selected row at entry.
        scroll.contentView.scroll(to: wasScrolledTo)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Push the current size decision into the two constraints -- the user's dragged
    /// size when there is one, the content's own fit otherwise, both clamped to the
    /// screen. Split out of setRows because a resize drag re-runs exactly this, many
    /// times a second, without rebuilding a single row.
    private func applySize() {
        let chromeH = chromeHeight ?? 0
        if let u = userSize {
            contentWidth.constant = Self.cardWidth(requested: u.width, screenWidth: clamp.width,
                                                   scale: s)
                - (chromeWidth ?? 0)
            scrollHeight.constant = Self.userListHeight(requested: u.height - chromeH,
                                                        screenHeight: clamp.height,
                                                        chrome: chromeH, scale: s)
        } else {
            // Only this branch reads the list's own fit, so only this branch pays for
            // laying the whole row list out -- a resize drag runs applySize per tick.
            list.layoutSubtreeIfNeeded()
            contentWidth.constant = Self.defaultContentWidth * s
            scrollHeight.constant = Self.listHeight(content: list.fittingSize.height,
                                                    screenHeight: clamp.height,
                                                    chrome: chromeH, scale: s)
        }
    }

    /// Re-fit the panel to the card while pinning the TOP-LEFT corner (AppKit origins
    /// are bottom-left, so growing height must drop the origin to keep the top edge
    /// fixed -- otherwise the header, and with it the Exit button, walks up the screen).
    ///
    /// The final clamp can MOVE that corner -- growing against the bottom or right edge
    /// pushes the card back onto the screen. That is why both resize paths report the
    /// position afterwards: a size the user can later shrink leaves the card where the
    /// clamp put it, and a stale stored offset would then teleport it on the next
    /// enter. (The auto-fit path does not report, deliberately: its height is a
    /// function of the row count, so `place` re-derives the same clamp on re-entry, and
    /// persisting a clamp that a later membership change undoes is the same bug
    /// inverted.)
    private func refit() {
        card.layoutSubtreeIfNeeded()
        let topY = panel.frame.maxY
        panel.setContentSize(card.fittingSize)
        var f = panel.frame
        f.origin.y = topY - f.height
        panel.setFrame(clampedFrame(f), display: true)
    }

    // MARK: - Resize (the bottom-right grip)

    private func beginResize() {
        resizeStart = (NSEvent.mouseLocation, panel.frame)
        resizeMoved = false
    }

    /// Called only for a press that cleared the grip's slop, so reaching here IS the
    /// evidence a real drag happened.
    private func dragResize() {
        guard let s = resizeStart else { return }
        resizeMoved = true
        let now = NSEvent.mouseLocation
        // Bottom-right grip with the top-left pinned: rightward is wider, and DOWNWARD
        // is taller -- which is a MINUS in AppKit's bottom-left origin, where dragging
        // down lowers y.
        userSize = NSSize(width: s.frame.width + (now.x - s.mouse.x),
                          height: s.frame.height - (now.y - s.mouse.y))
        applySize()
        refit()
        // Bank what the clamps ALLOWED rather than what the pointer asked for -- that
        // is the value endResize persists, and a raw 5000pt width stored from a drag
        // against the edge of a small display would come back as a 5000pt card on a
        // large one. (It does not change the rubber-band: every tick recomputes from
        // the mouse-down frame `s.frame`, which this never touches.)
        userSize = panel.frame.size
    }

    private func endResize() {
        let moved = resizeStart != nil && resizeMoved
        resizeStart = nil
        resizeMoved = false
        guard moved, let u = userSize else { return }
        onResize(Double(u.width), Double(u.height))
        reportMove()
    }

    /// Double-click the grip: hand the size back to the auto fit, on both axes.
    private func resetSize() {
        userSize = nil
        applySize()
        refit()
        onResize(0, 0)
        reportMove()
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
        // A size the user chose on one display can be too big for the one the mode
        // just moved to, so re-clamp here rather than waiting for the next setRows --
        // which a static fan (no membership or focus change) may never run.
        applySize()
        card.layoutSubtreeIfNeeded()
        panel.setContentSize(card.fittingSize)
        place(topLeft: topLeft)
    }

    func close() { panel.orderOut(nil) }
}

// MARK: - Views

/// A stack view whose origin is its TOP-LEFT.
///
/// NSView is unflipped by default, so a plain NSStackView used as a scroll view's
/// document view puts y=0 at the BOTTOM -- which made "scroll to 0" show the END of
/// the row list and hide row 1. Flipping it makes y grow downward, so a fresh panel
/// opens at the top and a saved offset means what it reads like.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

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

    init(index: Int, row: FanWidgetPanel.Row, scale s: CGFloat) {
        self.focused = row.focused
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7 * s
        if row.focused {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
        translatesAutoresizingMaskIntoConstraints = false

        let swatch = EdgeSwatchView(colorHex: row.color, side: row.side, scale: s)
        let icon = NSImageView()
        icon.image = AppCatalog.icon(forBundleId: row.bundleID)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: row.title.isEmpty ? "—" : row.title)
        title.font = .systemFont(ofSize: 13 * s, weight: row.focused ? .semibold : .regular)
        title.textColor = row.focused ? .white : NSColor.white.withAlphaComponent(0.88)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let hs = NSStackView(views: [swatch, icon, title])
        hs.orientation = .horizontal
        hs.alignment = .centerY
        hs.spacing = 9 * s
        hs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hs)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20 * s),
            icon.heightAnchor.constraint(equalToConstant: 20 * s),
            hs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 * s),
            hs.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6 * s),
            hs.topAnchor.constraint(equalTo: topAnchor, constant: 4 * s),
            hs.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4 * s),
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
    private let scale: CGFloat

    init(colorHex: String, side: String, scale: CGFloat) {
        self.color = NSColor(hexRGB: colorHex) ?? .controlAccentColor
        self.side = side
        self.scale = scale
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26 * scale),
            heightAnchor.constraint(equalToConstant: 20 * scale),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = scale
        let body = bounds.insetBy(dx: 1.5 * k, dy: 1.5 * k)
        // LABEL MODE sends an empty side: no window was moved, so no edge is
        // guaranteed exposed and drawing an edge glyph would point the user at a
        // strip that is not there. A plain filled chip carries the identity (the
        // colour matching the on-screen border) and claims nothing about position.
        if side.isEmpty {
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 4 * k, dy: 3 * k),
                               cornerWidth: 3 * k, cornerHeight: 3 * k, transform: nil))
            ctx.fillPath()
            return
        }
        // Window body: faint rounded outline.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 3 * k, cornerHeight: 3 * k, transform: nil))
        ctx.strokePath()
        // Exposed edge: a thick colored bar hugging the given side.
        ctx.setFillColor(color.cgColor)
        let t: CGFloat = 4 * k
        let bar: CGRect
        switch side {
        case "T": bar = CGRect(x: body.minX, y: body.maxY - t, width: body.width, height: t)
        case "B": bar = CGRect(x: body.minX, y: body.minY, width: body.width, height: t)
        case "L": bar = CGRect(x: body.minX, y: body.minY, width: t, height: body.height)
        default:  bar = CGRect(x: body.maxX - t, y: body.minY, width: t, height: body.height) // "R"
        }
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5 * k, cornerHeight: 1.5 * k, transform: nil))
        ctx.fillPath()
    }
}

/// The bottom-right resize grip: the three short diagonal strokes macOS has always
/// used for one. Its own view rather than a hit-test region on the card, because the
/// card's own mouseDown starts a DRAG and the row list sits on top of that corner --
/// a geometric test on the card would never be reached.
///
/// It reports the gesture and nothing else: every clamp, constraint and frame change
/// lives in the panel, so the view stays free of layout knowledge it would otherwise
/// duplicate.
private final class ResizeGripView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: (() -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14 * scale),
            heightAnchor.constraint(equalToConstant: 14 * scale),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// How far the pointer must travel before a press counts as a drag. AppKit
    /// delivers mouseDragged for hand tremor, so without this a bare CLICK on the grip
    /// pins the current size -- permanently ending the auto fit with nothing on screen
    /// to explain it, and only the undocumented double-click to undo it.
    private static let slop: CGFloat = 3
    private var downAt: NSPoint = .zero
    private var dragged = false
    /// Whether the PREVIOUS press of this click sequence turned into a drag. A
    /// fine-tuning drag of a few points leaves the second press inside the
    /// double-click distance, so `clickCount == 2` alone reads "grab it again to
    /// adjust" as "reset it" -- and throws away the size just set.
    private var previousDragged = false

    override func mouseDown(with e: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragged = false
        if e.clickCount == 2 && !previousDragged { onReset?() } else { onBegin?() }
    }
    override func mouseDragged(with e: NSEvent) {
        if !dragged {
            let now = NSEvent.mouseLocation
            guard abs(now.x - downAt.x) > Self.slop || abs(now.y - downAt.y) > Self.slop
            else { return }
            dragged = true
        }
        onDrag?()
    }
    override func mouseUp(with e: NSEvent) {
        previousDragged = dragged
        onEnd?()
    }

    // NO RESIZE CURSOR, and that is a hard constraint rather than an omission -- see
    // the measured note on HyperHintPanel's KeyCapView, which covers this same class of
    // panel: never key, in an app that is never active, which defeats every cursor
    // mechanism AppKit offers (cursor rects need a key window; `.activeAlways` tracking
    // is documented not to deliver `cursorUpdate`; and a cursor set by hand is
    // overridden by the frontmost app's within our own frame). The glyph below is the
    // affordance that works.

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.4 * scale)
        ctx.setLineCap(.round)
        for len in [4.0 * scale, 8.0 * scale, 12.0 * scale] as [CGFloat] {
            ctx.move(to: CGPoint(x: bounds.maxX - len, y: bounds.minY + 1))
            ctx.addLine(to: CGPoint(x: bounds.maxX - 1, y: bounds.minY + len))
        }
        ctx.strokePath()
    }
}

/// A small round translucent close button ("×") -- leaves the mode.
private final class CloseButtonView: NSView {
    var onClick: (() -> Void)?
    private var pressed = false

    init(scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10 * scale
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let x = NSTextField(labelWithString: "\u{2715}")
        x.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        x.textColor = NSColor.white.withAlphaComponent(0.75)
        x.translatesAutoresizingMaskIntoConstraints = false
        addSubview(x)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20 * scale),
            heightAnchor.constraint(equalToConstant: 20 * scale),
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
