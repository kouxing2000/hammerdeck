// memory_room's CONTRIBUTED overlay (co-located under the feature's swift/, like
// window_fan's FanWidgetPanel): driven only through the thin `room_panel_*` seam in
// Native+Panels.swift -- NOT a shared platform panel.
//
// The Hyper+L room: a dark vibrancy card holding the room picture with its places,
// a title above and a hint line below. Non-activating: it never takes focus from
// the app the user is about to leave or place. But CLICKABLE -- the room is there
// to be pointed at: a click on a place (or on one of its app icons) goes forward,
// a right-click anywhere on the room offers "Put <app> here" -- into the place
// under it, or a new one right there -- and a click anywhere off the places --
// on the room, the card, or any other app -- closes it. Every one of those reaches
// the feature as a pick (see adapter.roomPanel); the panel decides nothing itself.

import AppKit
import SwiftUI

@MainActor
final class RoomPanel {
    struct Spec {
        let title: String
        let image: String?       // the record's `image`: nil = the Study (see RoomImage)
        let pins: [RoomPinDisplay]
        let hint: String?
        let front: String?
        let showKeys: Bool
        let placeLabel: String?  // the right-click item; nil = no menu

        /// Parse the loosely-typed table that crosses the Lua seam.
        init(_ dict: [String: Any]) {
            title = dict["title"] as? String ?? "Memory Room"
            image = (dict["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            hint = dict["hint"] as? String
            front = dict["front"] as? String
            showKeys = dict["showKeys"] as? Bool ?? true
            placeLabel = (dict["placeLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            pins = (dict["pins"] as? [Any] ?? []).compactMap { v in
                guard let d = v as? [String: Any], let key = d["key"] as? String,
                      let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
                return RoomPinDisplay(id: key, key: key, name: d["name"] as? String ?? "",
                                      x: x, y: y,
                                      apps: (d["apps"] as? [Any] ?? []).compactMap { $0 as? String })
            }
        }
    }

    /// What a click asks for, one of three:
    /// - go to a place: `key`, with `app` = the icon's 1-based index in the
    ///   place's apps (nil = the place itself);
    /// - put the front app in a place: `key` + `place`;
    /// - put the front app right here, off every place: `at`, a unit point of the
    ///   room (0..1, top-left).
    struct Pick {
        var key: String? = nil
        var app: Int? = nil
        var place = false
        var at: CGPoint? = nil
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))
    private let spec: Spec
    private let onPick: (Pick?) -> Void
    private let hits = RoomHitView()
    private let hintLine = NSTextField(labelWithString: "")
    private var host: NSHostingView<RoomCanvas>?
    private var image: NSImage?
    private var scale: CGFloat = 1
    private var outsideClicks: Any?
    private var menuAction: RoomMenuAction?
    private var closed = false

    init(spec: Spec, onPick: @escaping (Pick?) -> Void) {
        self.spec = spec
        self.onPick = onPick
        hud.ignoresMouseEvents = false
        // The card's margins (title, hint line) are off every place too.
        hud.onBackgroundClick = { [weak self] in self?.pick(nil) }
        hits.onHover = { [weak self] in self?.hover($0) }
        hits.onClick = { [weak self] t in self?.pick(t.map { Pick(key: $0.key, app: $0.app) }) }
        hits.onRightClick = { [weak self] t, at, e in self?.showMenu(for: t, at: at, e) }
        render()
        // A click in any OTHER app means the user moved on: close, rather than
        // leave a room over their work that still holds the place letters.
        // (A global monitor never sees this app's own clicks -- those land above.)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pick(nil) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        hud.orderOut(nil)
    }

    private func pick(_ p: Pick?) {
        guard !closed else { return }
        onPick(p)
    }

    // MARK: - Drawing

    private func render() {
        // The pointer's screen, not NSScreen.main (the KEY screen): the room is
        // clicked, and on a multi-display desk it must open where the pointer is.
        let screen = NSScreen.underPointer
        let s = HUDScale.factor(for: screen)
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        image = RoomImage.load(spec.image)
        scale = s
        let aspect = RoomImage.aspect(image)

        // As wide as reads comfortably, but never so tall the card leaves the
        // screen: present() sets the card 30% up from the bottom, so the room
        // gets at most about half the height.
        var w = min(frame.width * 0.62, 560 * s)
        var h = w / aspect
        let maxH = frame.height * 0.5
        if h > maxH { h = maxH; w = h * aspect }

        hud.effect.layer?.cornerRadius = 16 * s
        let stack = hud.stack
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.alignment = .centerX
        stack.spacing = 10 * s
        stack.edgeInsets = NSEdgeInsets(top: 14 * s, left: 16 * s, bottom: 12 * s, right: 16 * s)

        stack.addArrangedSubview(label(spec.title.uppercased(), size: 11 * s, kern: 1.8 * s))

        // The picture (SwiftUI) under a transparent AppKit layer that takes the
        // mouse: this panel is never key and its app never active, and AppKit
        // tracking areas + mouseDown are what is measured to work there
        // (HyperHintPanel); the canvas reports where each place and icon landed.
        let host = NSHostingView(rootView: canvas(hovered: nil))
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

        if let hint = spec.hint {
            style(hintLine, hint, size: 11 * s, kern: 0)
            hintLine.lineBreakMode = .byTruncatingTail
            hintLine.maximumNumberOfLines = 1
            stack.addArrangedSubview(hintLine)
        }

        // lockSize: the hint line changes under hover, and nothing it says may
        // grow or shift a card the user is aiming into.
        hud.present(minWidth: w + 32 * s, lockSize: true, on: screen)
    }

    private func canvas(hovered: String?) -> RoomCanvas {
        RoomCanvas(image: image, pins: spec.pins, front: spec.front, selected: hovered,
                   scale: scale, showKeys: spec.showKeys,
                   onTargets: { [weak self] in self?.hits.targets = $0 })
    }

    /// Ring the place under the pointer, and name what a click there reaches in
    /// the hint line: the icon's app, or every app the place holds.
    private func hover(_ t: RoomTarget?) {
        host?.rootView = canvas(hovered: t?.key)
        guard let t, let pin = spec.pins.first(where: { $0.key == t.key }) else {
            hintLine.stringValue = spec.hint ?? ""
            return
        }
        let apps = t.app.map { i in pin.apps.indices.contains(i - 1) ? [pin.apps[i - 1]] : [] } ?? pin.apps
        let names = apps.map {
            AppCatalog.displayName(forBundleId: $0)
                ?? Strings.t("memoryRoom.page.uninstalled", default: "Uninstalled app")
        }
        hintLine.stringValue = names.isEmpty
            ? (spec.hint ?? "")
            : ListFormatter.localizedString(byJoining: names)
    }

    /// "Put <app> here": into the place right-clicked, or, off every place, a new
    /// one exactly where the click was.
    private func showMenu(for t: RoomTarget?, at: CGPoint, _ event: NSEvent) {
        guard let title = spec.placeLabel else { return }
        let pick = t.map { Pick(key: $0.key, place: true) } ?? Pick(at: at)
        let action = RoomMenuAction { [weak self] in self?.pick(pick) }
        menuAction = action                       // NSMenuItem.target is weak
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: #selector(RoomMenuAction.fire), keyEquivalent: "")
        item.target = action
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: hits)
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
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: kern])
    }
}

/// The room's mouse: hover, click, right-click (or Control-click), over the
/// canvas's reported targets. Flipped, so its coordinates are the canvas's
/// (top-left origin).
@MainActor
private final class RoomHitView: NSView {
    var targets: [RoomTarget] = []
    var onHover: ((RoomTarget?) -> Void)?
    /// nil = a click off every place.
    var onClick: ((RoomTarget?) -> Void)?
    /// The place (or icon) right-clicked, nil off every place; and where, as a
    /// unit point of the room.
    var onRightClick: ((RoomTarget?, CGPoint, NSEvent) -> Void)?
    private var tracking: NSTrackingArea?
    private var hovered: RoomTarget?
    private var pressing: RoomTarget?

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

    /// What is under a point: an app icon before the place around it, and the
    /// smaller place where two overlap. A few points of slack, so a chip's edge
    /// counts.
    private func target(at p: NSPoint) -> RoomTarget? {
        let hits = targets.filter { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }
        return hits.first { $0.app != nil }
            ?? hits.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    private func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }

    private func unit(_ p: NSPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / max(1, bounds.width))),
                y: min(1, max(0, p.y / max(1, bounds.height))))
    }

    private func rightClick(_ e: NSEvent) {
        let p = point(e)
        onRightClick?(target(at: p), unit(p), e)
    }

    private func setHovered(_ t: RoomTarget?) {
        guard t != hovered else { return }
        hovered = t
        onHover?(t)
    }

    override func mouseMoved(with e: NSEvent) { setHovered(target(at: point(e))) }
    override func mouseEntered(with e: NSEvent) { setHovered(target(at: point(e))) }
    override func mouseExited(with e: NSEvent) { setHovered(nil) }

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightClick(e); return }
        let t = target(at: point(e))
        // Off every place: close at once. On one: wait for the release, so a
        // press dragged off the place is a change of mind, as with any button.
        if let t { pressing = t } else { onClick?(nil) }
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressing = nil }
        guard let p = pressing, target(at: point(e)) == p else { return }
        onClick?(p)
    }

    override func rightMouseDown(with e: NSEvent) { rightClick(e) }
}

/// The right-click item's target (NSMenuItem needs an @objc receiver).
@MainActor
private final class RoomMenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
