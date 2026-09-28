// memory_room's CONTRIBUTED overlay (co-located under the feature's swift/, like
// window_fan's FanWidgetPanel): driven only through the thin `room_panel_*` seam in
// Native+Panels.swift -- NOT a shared platform panel.
//
// The Hyper+L room: a dark vibrancy card holding the room picture with one app's
// windows on it, the app's name above and a hint line below. Non-activating: it
// never takes focus from the window the user is about to leave. But CLICKABLE --
// the room is there to be pointed at: a click on a window brings it forward,
// dragging one moves its spot, and a click anywhere off the windows -- on the room,
// the card, or any other app -- closes it. Each of those reaches the feature as a
// pick (see adapter.roomPanel); the panel decides nothing itself. Hovering a window
// also shows its picture (Native+Capture), when Screen Recording allows it.
//
// The frame -- the card behind the picture, the app's name, the hint line -- is
// thin, and it steps back: shown as the room opens, faded after a few seconds, and
// back while a window is hovered (the hint line then carries its full title). A
// close button stays put through all of it.

import AppKit
import SwiftUI

@MainActor
final class RoomPanel {
    struct Spec {
        let title: String
        let image: String?       // the record's `image`: nil = the Study (see RoomImage)
        let pins: [RoomPinDisplay]
        let hint: String?
        let front: String?       // the id of the window in front
        let wids: [String: CGWindowID]   // pin id -> its window, for the preview
        let foot: CGSize         // room.lua's R.FOOT: how close two spots may be (RoomCanvas.landing)

        /// Parse the loosely-typed table that crosses the Lua seam.
        init(_ dict: [String: Any]) {
            title = dict["title"] as? String ?? "Memory Room"
            image = (dict["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            hint = dict["hint"] as? String
            front = dict["front"] as? String
            let f = dict["foot"] as? [String: Any]
            foot = CGSize(width: (f?["w"] as? Double) ?? 0, height: (f?["h"] as? Double) ?? 0)
            var wids: [String: CGWindowID] = [:]
            for case let d as [String: Any] in dict["pins"] as? [Any] ?? [] {
                if let id = d["id"] as? String, let n = (d["wid"] as? NSNumber)?.uint32Value, n != 0 {
                    wids[id] = n
                }
            }
            self.wids = wids
            pins = (dict["pins"] as? [Any] ?? []).compactMap { v in
                guard let d = v as? [String: Any], let id = d["id"] as? String,
                      let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
                return RoomPinDisplay(id: id, name: d["name"] as? String ?? "",
                                      title: d["title"] as? String ?? "", x: x, y: y,
                                      apps: (d["apps"] as? [Any] ?? []).compactMap { $0 as? String })
            }
        }
    }

    /// What a click asks for: bring window `id` forward, or -- `movedTo` set, a unit
    /// point of the room (0..1, top-left) -- keep it there from now on.
    struct Pick {
        let id: String
        var movedTo: CGPoint? = nil
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
    private let spec: Spec
    private let onPick: (Pick?) -> Void
    private let hits = RoomHitView()
    private let hintLine = NSTextField(labelWithString: "")
    private var titleLine: NSTextField?
    private let closeButton = RoomCloseButton()
    private var hideFrame: Task<Void, Never>?
    private var host: NSHostingView<RoomCanvas>?
    private var image: NSImage?
    private var scale: CGFloat = 1
    /// The pins as drawn: a drag moves one here -- to where it will land, not under
    /// the pointer -- and it stays where it was let go for as long as this room is open.
    private var pins: [RoomPinDisplay]
    private var hovered: String?
    private var dragging = false
    /// Each window's picture, taken the first time it is hovered in this open.
    private var previews: [String: NSImage] = [:]
    private var capturing: Set<String> = []
    private var shots: AnyObject?            // Native.WindowShots, on macOS 14+
    private var outsideClicks: Any?
    private var closed = false

    init(spec: Spec, onPick: @escaping (Pick?) -> Void) {
        self.spec = spec
        self.onPick = onPick
        self.pins = spec.pins
        hud.ignoresMouseEvents = false
        // The card's margins (title, hint line) are off every window too.
        hud.onBackgroundClick = { [weak self] in self?.pick(nil) }
        hits.foot = spec.foot
        hits.onHover = { [weak self] in self?.hover($0) }
        hits.onClick = { [weak self] t in self?.pick(t.map { Pick(id: $0.id) }) }
        hits.onDrag = { [weak self] t, at in self?.drag(t, to: at) }
        closeButton.onClick = { [weak self] in self?.pick(nil) }
        hits.onDrop = { [weak self] t, at in
            guard let self else { return }
            // Drawn where it landed (next to an icon it was dropped on), then saved there.
            self.drag(t, to: at)
            self.dragging = false
            self.redraw()
            self.pick(Pick(id: t.id, movedTo: at))
        }
        mountFrame()
        render()
        setFrameShown(true, animated: false)
        fadeFrame(after: Self.frameLinger)
        // A click in any OTHER app means the user moved on: close, rather than
        // leave a room over their work that still holds Escape.
        // (A global monitor never sees this app's own clicks -- those land above.)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pick(nil) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        hideFrame?.cancel()
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        hud.orderOut(nil)
    }

    private func pick(_ p: Pick?) {
        guard !closed else { return }
        onPick(p)
    }

    // MARK: - Drawing

    /// How long the frame stays after the room opens, or after the pointer leaves a window.
    private static let frameLinger: Duration = .seconds(3)
    private static let frameAfterHover: Duration = .milliseconds(600)

    /// The picture must sit OUTSIDE the vibrancy view, or fading the card would fade
    /// it too: the card becomes a backdrop beside the content, under one dark root.
    private func mountFrame() {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .vibrantDark)
        hud.stack.removeFromSuperview()
        hud.contentView = root
        for v in [hud.effect, hud.stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)
    }

    private func setFrameShown(_ on: Bool, animated: Bool = true) {
        let views: [NSView] = [hud.effect, hintLine] + (titleLine.map { [$0] } ?? [])
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.25 : 0
            for v in views { v.animator().alphaValue = on ? 1 : 0 }
        }, completionHandler: { [weak self] in
            // The shadow follows what is drawn: the card, or the picture alone.
            MainActor.assumeIsolated { self?.hud.invalidateShadow() }
        })
    }

    private func fadeFrame(after delay: Duration) {
        hideFrame?.cancel()
        hideFrame = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.closed else { return }
            self.setFrameShown(false)
        }
    }

    private func render() {
        // The pointer's screen, not NSScreen.main (the KEY screen): the room is
        // clicked, and on a multi-display desk it must open where the pointer is.
        let screen = NSScreen.underPointer
        let s = HUDScale.factor(for: screen)
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        image = RoomImage.load(spec.image)
        scale = s
        let aspect = RoomImage.aspect(image)

        // Most of the screen: the picture is what the windows are remembered by,
        // and the room is up only for the moment it takes to point. Centred, so
        // the card (picture, title, hint) keeps a margin top and bottom.
        var w = min(frame.width * 0.85, 720 * s)
        var h = w / aspect
        let maxH = frame.height * 0.7
        if h > maxH { h = maxH; w = h * aspect }

        // A thin frame: the picture's corners (10) plus the margin make the card's.
        let margin = 6 * s
        hud.effect.layer?.cornerRadius = 10 * s + margin
        let stack = hud.stack
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.alignment = .centerX
        stack.spacing = 4 * s
        stack.edgeInsets = NSEdgeInsets(top: 5 * s, left: margin, bottom: 5 * s, right: margin)

        let title = label(spec.title.uppercased(), size: 9 * s, kern: 1.4 * s)
        titleLine = title
        stack.addArrangedSubview(title)

        // The picture (SwiftUI) under a transparent AppKit layer that takes the
        // mouse: this panel is never key and its app never active, and AppKit
        // tracking areas + mouse events are what is measured to work there
        // (HyperHintPanel); the canvas reports where each window landed.
        let host = NSHostingView(rootView: canvas())
        self.host = host
        let box = NSView()
        for v in [host, hits] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                v.topAnchor.constraint(equalTo: box.topAnchor),
                v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: w),
            box.heightAnchor.constraint(equalToConstant: h),
        ])
        stack.addArrangedSubview(box)
        // On the picture's own corner, so it belongs to the picture whether the
        // frame is shown or not (on the frame's corner it floats alone once faded).
        closeButton.size = 12 * s
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 7 * s),
            closeButton.topAnchor.constraint(equalTo: box.topAnchor, constant: 7 * s),
            closeButton.widthAnchor.constraint(equalToConstant: 12 * s),
            closeButton.heightAnchor.constraint(equalToConstant: 12 * s),
        ])

        if let hint = spec.hint {
            style(hintLine, hint, size: 10 * s, kern: 0)
            hintLine.lineBreakMode = .byTruncatingMiddle
            hintLine.maximumNumberOfLines = 1
            stack.addArrangedSubview(hintLine)
        }

        // lockSize: the hint line changes under hover, and nothing it says may
        // grow or shift a card the user is aiming into.
        hud.present(minWidth: w + 2 * margin, lockSize: true, on: screen, centered: true)
    }

    private func canvas() -> RoomCanvas {
        // No picture while a window is dragged: it would cover where it is going.
        let shown = dragging ? nil : hovered.flatMap { id in previews[id].map { RoomPreview(id: id, image: $0) } }
        return RoomCanvas(image: image, pins: pins, front: spec.front, selected: hovered,
                          scale: scale,
                          onTargets: { [weak self] in self?.hits.targets = $0 },
                          preview: shown)
    }

    private func redraw() { host?.rootView = canvas() }

    /// Ring the window under the pointer, and put its full title in the hint line.
    private func hover(_ t: RoomTarget?) {
        hovered = t?.id
        redraw()
        let title = t.flatMap { t in pins.first { $0.id == t.id }?.title } ?? ""
        hintLine.stringValue = title.isEmpty ? (spec.hint ?? "") : title
        // The frame comes back while a window is hovered: its hint line is where
        // the window's full title shows.
        if let t {
            hideFrame?.cancel()
            setFrameShown(true)
            capture(t.id)
        } else {
            fadeFrame(after: Self.frameAfterHover)
        }
    }

    /// Take window `id`'s picture, once per open, and draw it if the pointer is
    /// still on that window when it lands (~40 ms). Without Screen Recording the
    /// first hover asks for it; until it is granted, hover shows the title only.
    private func capture(_ id: String) {
        guard previews[id] == nil, !capturing.contains(id), let wid = spec.wids[id] else { return }
        guard Native.canCaptureWindows else { Native.requestWindowCapture(); return }
        guard #available(macOS 14.0, *) else { return }
        let shots = (self.shots as? Native.WindowShots) ?? Native.WindowShots()
        self.shots = shots
        // As many pixels as the bubble can show: under half the room's width.
        let width = Int((host?.bounds.width ?? 560) * 0.45 * (hud.backingScaleFactor))
        capturing.insert(id)
        Task { [weak self] in
            let image = await shots.image(of: wid, width: width)
            guard let self, !self.closed else { return }
            self.capturing.remove(id)
            guard let image else { return }
            self.previews[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            if self.hovered == id { self.redraw() }
        }
    }

    /// A drag in progress: the icon sits where it would land if let go now
    /// (RoomHitView reports RoomCanvas.landing, not the raw pointer), so the drop
    /// never jumps.
    private func drag(_ t: RoomTarget, to at: CGPoint) {
        guard let i = pins.firstIndex(where: { $0.id == t.id }) else { return }
        let p = pins[i]
        pins[i] = RoomPinDisplay(id: p.id, name: p.name, title: p.title,
                                 x: Double(at.x), y: Double(at.y), apps: p.apps)
        hovered = t.id
        dragging = true
        redraw()
    }

    private func label(_ text: String, size: CGFloat, kern: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        style(f, text, size: size, kern: kern)
        return f
    }

    private func style(_ f: NSTextField, _ text: String, size: CGFloat, kern: CGFloat) {
        f.alignment = .center
        f.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            // Explicit: these sit beside the vibrancy card, not in it, so the
            // semantic colours lose the brightening they are tuned for.
            .foregroundColor: NSColor(white: 1, alpha: 0.72),
            .kern: kern])
    }
}

/// The room's close button: a click on it closes the room like any click off the
/// windows, but it is there to be found -- and it stays when the frame fades.
@MainActor
private final class RoomCloseButton: NSView {
    var onClick: (() -> Void)?
    var size: CGFloat = 13 { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.12, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1
        ring.stroke()
        let k = r.width * 0.3
        let x = NSBezierPath()
        x.move(to: NSPoint(x: r.midX - k, y: r.midY - k)); x.line(to: NSPoint(x: r.midX + k, y: r.midY + k))
        x.move(to: NSPoint(x: r.midX - k, y: r.midY + k)); x.line(to: NSPoint(x: r.midX + k, y: r.midY - k))
        x.lineWidth = max(1.2, r.width * 0.11)
        x.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.9).setStroke()
        x.stroke()
    }
}

/// The room's mouse: hover, click, drag, over the canvas's reported targets.
/// Flipped, so its coordinates are the canvas's (top-left origin).
@MainActor
private final class RoomHitView: NSView {
    var targets: [RoomTarget] = []
    /// How close two spots may be, as a fraction of the room (RoomCanvas.landing).
    var foot: CGSize = .zero
    var onHover: ((RoomTarget?) -> Void)?
    /// nil = a click off every window.
    var onClick: ((RoomTarget?) -> Void)?
    /// A window being dragged, and where it would land if let go now (a unit point
    /// of the room): the drag shows the landing, so the drop never jumps.
    var onDrag: ((RoomTarget, CGPoint) -> Void)?
    /// Where it was let go: the same landing -- beside, never on, another window.
    var onDrop: ((RoomTarget, CGPoint) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered: RoomTarget?
    private var pressing: RoomTarget?
    private var pressedAt: NSPoint = .zero
    /// From the pointer to the grabbed window's centre (its spot), so a drag moves
    /// the window from where it was grabbed instead of snapping it under the pointer.
    private var grab: CGVector = .zero
    private var dragging = false

    override var isFlipped: Bool { true }

    /// This panel is never key; see HyperHintPanel's measurement -- kept true so
    /// the first click is a click, whatever AppKit decides about the gate.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// The window under a point: the smaller one where two overlap. A few points
    /// of slack, so a chip's edge counts.
    private func target(at p: NSPoint) -> RoomTarget? {
        targets.filter { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    private func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }

    private func unit(_ p: NSPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / max(1, bounds.width))),
                y: min(1, max(0, p.y / max(1, bounds.height))))
    }

    private func setHovered(_ t: RoomTarget?) {
        guard t != hovered else { return }
        hovered = t
        onHover?(t)
    }

    override func mouseMoved(with e: NSEvent) { setHovered(target(at: point(e))) }
    override func mouseEntered(with e: NSEvent) { setHovered(target(at: point(e))) }
    override func mouseExited(with e: NSEvent) { if !dragging { setHovered(nil) } }

    override func mouseDown(with e: NSEvent) {
        // Off every window: close at once. On one: wait -- the release makes it a
        // click, a move past a few points makes it a drag.
        let p = point(e)
        guard let t = target(at: p) else { onClick?(nil); return }
        (pressing, pressedAt, dragging) = (t, p, false)
        grab = CGVector(dx: t.rect.midX - p.x, dy: t.rect.midY - p.y)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let t = pressing else { return }
        let p = point(e)
        if !dragging, hypot(p.x - pressedAt.x, p.y - pressedAt.y) < 4 { return }
        dragging = true
        onDrag?(t, landing(t, p))
    }

    /// Where `t` lands when let go with the pointer at `p` (RoomCanvas.landing), as
    /// a unit point of the room.
    private func landing(_ t: RoomTarget, _ p: NSPoint) -> CGPoint {
        let drop = NSPoint(x: p.x + grab.dx, y: p.y + grab.dy)
        let others = targets.filter { $0.id != t.id }.map(\.rect)
        return unit(RoomCanvas.landing(for: drop, size: t.rect.size, others: others, foot: foot, in: bounds.size))
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressing = nil; dragging = false }
        guard let t = pressing else { return }
        let p = point(e)
        if dragging {
            onDrop?(t, landing(t, p))
        } else if target(at: p)?.id == t.id {
            onClick?(t)
        }
    }
}
