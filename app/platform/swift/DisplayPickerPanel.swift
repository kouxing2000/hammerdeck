// Panels.swift split: one self-owned native UI surface (see Panels.swift for the
// shared FloatingPanel base and the rationale for our own panels).
//
// A one-shot SPATIAL display picker: it draws every display as a scaled rectangle
// at its real relative position (like System Settings > Displays > "Arrange
// Displays"), so you recognise a screen by WHERE it is, not by its name. Each
// display shows its name, resolution, and window count. The user selects
// displays by clicking them (a green ring + corner check); `selectCount` sets how
// many are needed to confirm.
//
// Reusable across features via `selectCount` + `preselect` + `confirmVerb`:
//   * Window Snap "swap windows between displays": selectCount = 2, verb "Swap".
//     The two are the swap pair -- either can be changed; the active display is
//     merely a DEFAULT (passed LAST in `preselect` so it stays selected when the
//     user clicks a new partner). There is no locked "current" -- pick any two.
//   * A "which display?" pick (e.g. Window Deck's target): selectCount = 1, verb
//     "Deck on"; clicking a new display replaces the selection.
//
// Selection is FIFO-capped at `selectCount`: clicking a selected display
// deselects it; clicking an unselected one adds it and drops the OLDEST when that
// would exceed the cap (so the last-passed `preselect` entry is "sticky"). It
// does NOT reuse ChooserPanel / WindowPickerPanel (text lists) -- the point here
// is the spatial map, a custom-drawn NSView. onDone gets the 1-based selected
// indices, or nil on cancel.

import AppKit

struct DisplayEntry {
    let frame: CGRect   // top-left-origin global points (as the Lua seam speaks)
    let name: String
    let windows: Int    // window count to show; < 0 = unknown (not drawn)
}

@MainActor
final class DisplayPickerPanel: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let confirmButton = NSButton()
    private let mapView: DisplayMapView

    private let entries: [DisplayEntry]
    private let selectCount: Int
    private let confirmVerb: String
    private var selected: [Int]             // 0-based, FIFO-ordered, capped at selectCount
    private let onDone: ([Int]?) -> Void    // 1-based selection, or nil on cancel

    private var keyMonitor: Any?
    private var isClosing = false

    private static let width: CGFloat = 520
    private static let mapHeight: CGFloat = 214
    private static let edgeInset: CGFloat = 20
    private static let footerBottomPad: CGFloat = 14

    /// - `preselect`: 1-based indices selected by default (deduped, clamped to
    ///   `selectCount`). Pass the display you want "sticky" LAST.
    init(title: String, prompt: String, entries: [DisplayEntry], preselect: [Int],
         selectCount: Int, confirmVerb: String, onDone: @escaping ([Int]?) -> Void) {
        self.entries = entries
        self.selectCount = max(1, selectCount)
        self.confirmVerb = confirmVerb
        self.onDone = onDone
        // Seed the selection from preselect: valid, deduped, keep the LAST N.
        var seed: [Int] = []
        for one in preselect {
            let z = one - 1
            guard z >= 0, z < entries.count, !seed.contains(z) else { continue }
            seed.append(z)
        }
        while seed.count > self.selectCount { seed.removeFirst() }
        self.selected = seed
        self.mapView = DisplayMapView(entries: entries)

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: DisplayPickerPanel.width, height: 340),
                              level: .floating,
                              collectionBehavior: [.canJoinAllSpaces, .transient],
                              keyable: true, mouseTransparent: false)
        super.init()
        panel.hidesOnDeactivate = false

        let content = NSVisualEffectView()
        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = title
        content.addSubview(titleLabel)

        promptLabel.font = .systemFont(ofSize: 12)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.lineBreakMode = .byWordWrapping
        promptLabel.maximumNumberOfLines = 2
        promptLabel.stringValue = prompt
        content.addSubview(promptLabel)

        mapView.selected = selected
        mapView.onClickDisplay = { [weak self] idx in self?.toggle(idx) }
        content.addSubview(mapView)

        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.stringValue = selectCount == 1
            ? "click a display    \u{23CE}  confirm"
            : "click to change the pair    \u{23CE}  confirm"
        content.addSubview(hintLabel)

        cancelButton.bezelStyle = .rounded
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        content.addSubview(cancelButton)

        confirmButton.bezelStyle = .rounded
        confirmButton.bezelColor = .controlAccentColor
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        content.addSubview(confirmButton)

        panel.contentView = content
        panel.delegate = self
        refreshConfirmTitle()
    }

    // MARK: public API

    var isVisible: Bool { panel.isVisible }

    /// `screen` (AppKit coords) centers the picker on that display; without it,
    /// the main screen.
    func show(on screen: NSRect? = nil) {
        isClosing = false
        layout()
        if let target = screen ?? NSScreen.main?.visibleFrame {
            var f = panel.frame
            f.origin.x = target.midX - f.width / 2
            f.origin.y = target.midY - f.height / 2 + 40
            panel.setFrame(f, display: true)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        installKeys()
    }

    func close() {
        isClosing = true
        removeKeys()
        panel.orderOut(nil)
    }

    // Test drivers (used by the gated swift integration tests; the headless Lua
    // suite drives the fake adapter's own picker). Not part of the Lua contract.
    var selectedOneBased: [Int] { selected.map { $0 + 1 } }
    var displayCount: Int { entries.count }
    func debugToggle(_ oneBased: Int) { toggle(oneBased - 1) }
    func debugConfirm() { confirm() }
    func debugCancel() { cancel() }

    // MARK: selection

    /// Toggle a display in/out of the selection; FIFO-drop the oldest when a new
    /// pick would exceed `selectCount`, so selecting is always responsive.
    private func toggle(_ i: Int) {
        guard i >= 0, i < entries.count else { return }
        if let pos = selected.firstIndex(of: i) {
            selected.remove(at: pos)
        } else {
            selected.append(i)
            while selected.count > selectCount { selected.removeFirst() }
        }
        mapView.selected = selected
        mapView.needsDisplay = true
        refreshConfirmTitle()
    }

    private func refreshConfirmTitle() {
        // A pick-ONE names its target ("Deck on DELL"); a pick-many (the swap pair)
        // just uses the verb ("Swap") -- naming a transient single mid-change reads
        // oddly and lengthens the button.
        let label: String
        if selectCount == 1, selected.count == 1, entries.indices.contains(selected[0]) {
            label = "\(confirmVerb) \(entries[selected[0]].name)"
        } else {
            label = confirmVerb
        }
        confirmButton.attributedTitle = NSAttributedString(string: "\u{23CE}  \(label)", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        confirmButton.isEnabled = selected.count == selectCount
        layoutFooter()
    }

    // MARK: keyboard (local monitor)

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 36, 76: self.confirm(); return nil   // return / enter
            case 53:     self.cancel();  return nil   // escape
            default:     return event
            }
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    @objc private func confirmClicked() { confirm() }
    @objc private func cancelClicked() { cancel() }

    private func confirm() {
        guard selected.count == selectCount else { NSSound.beep(); return }
        finish(selected.map { $0 + 1 })
    }

    private func cancel() { finish(nil) }

    private func finish(_ result: [Int]?) {
        guard !isClosing else { return }
        isClosing = true
        removeKeys()
        if panel.isVisible { panel.orderOut(nil) }
        onDone(result)
    }

    // MARK: NSWindowDelegate -- click-away dismiss (Spotlight convention)

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, panel.isVisible else { return }
        finish(nil)
    }

    // MARK: layout

    private func layout() {
        let W = DisplayPickerPanel.width
        let E = DisplayPickerPanel.edgeInset
        let topPad: CGFloat = 16, bottomPad: CGFloat = 14
        let titleH: CGFloat = 22, promptH: CGFloat = 34, footerH: CGFloat = 30

        let total = topPad + titleH + 4 + promptH + 12
            + DisplayPickerPanel.mapHeight + 14 + footerH + bottomPad

        var f = panel.frame
        let topEdge = f.maxY
        f.size = NSSize(width: W, height: total)
        f.origin.y = topEdge - total
        panel.setFrame(f, display: true)
        panel.contentView!.frame = NSRect(origin: .zero, size: f.size)

        var y = total - topPad
        titleLabel.frame = NSRect(x: E, y: y - titleH, width: W - 2 * E, height: titleH)
        y -= titleH + 4
        promptLabel.frame = NSRect(x: E, y: y - promptH, width: W - 2 * E, height: promptH)
        y -= promptH + 12
        mapView.frame = NSRect(x: E, y: y - DisplayPickerPanel.mapHeight,
                               width: W - 2 * E, height: DisplayPickerPanel.mapHeight)
        mapView.needsDisplay = true
        layoutFooter()
    }

    private func layoutFooter() {
        let W = DisplayPickerPanel.width
        let E = DisplayPickerPanel.edgeInset
        let bh: CGFloat = 30
        let by = DisplayPickerPanel.footerBottomPad

        confirmButton.sizeToFit()
        let sw = max(120, confirmButton.frame.width + 22)
        confirmButton.frame = NSRect(x: W - E - sw, y: by, width: sw, height: bh)

        cancelButton.sizeToFit()
        let cw = max(78, cancelButton.frame.width + 16)
        let cancelX = W - E - sw - 10 - cw
        cancelButton.frame = NSRect(x: cancelX, y: by, width: cw, height: bh)

        // Clamp the hint so it can never run under the Cancel button (the overlap
        // bug): it lives left of Cancel and truncates if there isn't room.
        let hintW = max(0, cancelX - E - 10)
        hintLabel.frame = NSRect(x: E, y: by + (bh - 15) / 2, width: hintW, height: 15)
    }
}

// MARK: - The spatial map

/// Draws the displays as scaled rounded rects at their real relative positions
/// (the seam speaks top-left-origin global points; this view flips Y into its own
/// bottom-left space). Pure drawing + hit-testing: the panel owns selection state
/// and passes the selected indices down.
@MainActor
final class DisplayMapView: NSView {
    private let entries: [DisplayEntry]
    var selected: [Int] = []
    var onClickDisplay: ((Int) -> Void)?

    private var drawnRects: [CGRect] = []   // view-space, index-aligned to entries

    init(entries: [DisplayEntry]) {
        self.entries = entries
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// Map each display's global frame into this view, preserving the arrangement.
    private func computeRects() {
        drawnRects = Array(repeating: .zero, count: entries.count)
        guard !entries.isEmpty else { return }
        var bbox = entries[0].frame
        for e in entries { bbox = bbox.union(e.frame) }
        guard bbox.width > 0, bbox.height > 0 else { return }

        let pad: CGFloat = 18
        let availW = bounds.width - 2 * pad
        let availH = bounds.height - 2 * pad
        let scale = min(availW / bbox.width, availH / bbox.height)
        let mapW = bbox.width * scale, mapH = bbox.height * scale
        let offX = (bounds.width - mapW) / 2
        let offY = (bounds.height - mapH) / 2

        for (i, e) in entries.enumerated() {
            let relX = (e.frame.minX - bbox.minX) * scale
            let relTop = (e.frame.minY - bbox.minY) * scale
            let w = e.frame.width * scale, h = e.frame.height * scale
            // Flip vertically: a display physically higher (smaller top-left y)
            // must appear higher (larger view y).
            drawnRects[i] = CGRect(x: offX + relX, y: offY + (mapH - relTop - h), width: w, height: h)
        }
    }

    override func layout() {
        super.layout()
        computeRects()
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawnRects.count != entries.count { computeRects() }
        guard NSGraphicsContext.current != nil else { return }

        let wallpaper = NSGradient(colors: [
            NSColor(srgbRed: 0.56, green: 0.83, blue: 0.91, alpha: 1),
            NSColor(srgbRed: 0.25, green: 0.58, blue: 0.71, alpha: 1),
            NSColor(srgbRed: 0.11, green: 0.37, blue: 0.49, alpha: 1),
        ])
        let green = NSColor(srgbRed: 0.18, green: 0.70, blue: 0.31, alpha: 1)

        // Connector between the two selected displays (drawn under the rects).
        if selected.count == 2, drawnRects.indices.contains(selected[0]),
           drawnRects.indices.contains(selected[1]) {
            let a = CGPoint(x: drawnRects[selected[0]].midX, y: drawnRects[selected[0]].midY)
            let b = CGPoint(x: drawnRects[selected[1]].midX, y: drawnRects[selected[1]].midY)
            let line = NSBezierPath()
            line.move(to: a); line.line(to: b)
            line.lineWidth = 2
            line.setLineDash([5, 4], count: 2, phase: 0)
            green.withAlphaComponent(0.85).setStroke()
            line.stroke()
        }

        for (i, r) in drawnRects.enumerated() {
            let rect = r.insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            let isSelected = selected.contains(i)

            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            wallpaper?.draw(in: rect, angle: -55)
            if isSelected { green.withAlphaComponent(0.28).setFill(); rect.fill() }
            NSGraphicsContext.current?.restoreGraphicsState()

            path.lineWidth = isSelected ? 3 : 1.5
            (isSelected ? green : NSColor.black.withAlphaComponent(0.22)).setStroke()
            path.stroke()

            drawLabel(entries[i], in: rect)
            if isSelected { drawCheck(in: rect, color: green) }
        }
    }

    /// Name / window-count / resolution, centered -- no corner pill to collide
    /// with (the overlap bug). Clipped to the display rect on very small maps.
    private func drawLabel(_ e: DisplayEntry, in rect: CGRect) {
        let box = rect.insetBy(dx: 5, dy: 5)
        guard box.width > 24 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail

        let name = e.name.isEmpty ? "Display" : e.name
        (name as NSString).draw(in: CGRect(x: box.minX, y: box.midY + 6, width: box.width, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: NSColor.white, .paragraphStyle: para])

        if e.windows >= 0 {
            let n = e.windows
            let text = n == 1 ? "1 window" : "\(n) windows"
            (text as NSString).draw(in: CGRect(x: box.minX, y: box.midY - 8, width: box.width, height: 14),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                 .foregroundColor: NSColor(white: 1, alpha: 0.95), .paragraphStyle: para])
        }

        let res = "\(Int(e.frame.width.rounded())) \u{00D7} \(Int(e.frame.height.rounded()))"
        (res as NSString).draw(in: CGRect(x: box.minX, y: box.midY - 22, width: box.width, height: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 9.5),
                             .foregroundColor: NSColor(white: 1, alpha: 0.8), .paragraphStyle: para])
    }

    /// A small green check disc in the top-right corner -- clear of the centered
    /// label, so it never overlaps the name.
    private func drawCheck(in rect: CGRect, color: NSColor) {
        guard rect.width > 46, rect.height > 40 else { return }
        let d: CGFloat = 17
        let c = CGRect(x: rect.maxX - d - 5, y: rect.maxY - d - 5, width: d, height: d)
        let disc = NSBezierPath(ovalIn: c)
        color.setFill(); disc.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        disc.lineWidth = 1; disc.stroke()
        let check = NSBezierPath()
        check.move(to: CGPoint(x: c.minX + 4.5, y: c.midY + 0.2))
        check.line(to: CGPoint(x: c.midX - 0.8, y: c.minY + 5))
        check.line(to: CGPoint(x: c.maxX - 4, y: c.maxY - 5))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor.white.setStroke(); check.stroke()
    }

    // MARK: hit testing

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in drawnRects.enumerated() where r.insetBy(dx: 3, dy: 3).contains(p) {
            onClickDisplay?(i)
            return
        }
    }
}
