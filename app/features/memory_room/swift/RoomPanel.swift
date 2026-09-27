// memory_room's CONTRIBUTED overlay (co-located under the feature's swift/, like
// window_fan's FanWidgetPanel): driven only through the thin `room_panel_*` seam in
// Native+Panels.swift -- NOT a shared platform panel.
//
// The Hyper+L room: a dark vibrancy card holding the room picture with its pins,
// a title above and the key legend below. Non-activating and mouse-transparent,
// like the Window Mode HUD: it is shown while a keyboard modal is live, and must
// never take focus from the app the user is about to place or leave.

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

        /// Parse the loosely-typed table that crosses the Lua seam.
        init(_ dict: [String: Any]) {
            title = dict["title"] as? String ?? "Memory Room"
            image = (dict["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            hint = dict["hint"] as? String
            front = dict["front"] as? String
            pins = (dict["pins"] as? [Any] ?? []).compactMap { v in
                guard let d = v as? [String: Any], let key = d["key"] as? String,
                      let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
                return RoomPinDisplay(id: key, key: key, name: d["name"] as? String ?? "",
                                      x: x, y: y,
                                      apps: (d["apps"] as? [Any] ?? []).compactMap { $0 as? String })
            }
        }
    }

    private let hud = VibrancyHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400))

    init(spec: Spec) { render(spec) }

    func close() { hud.orderOut(nil) }

    private func render(_ spec: Spec) {
        let screen = NSScreen.main
        let s = HUDScale.factor(for: screen)
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let image = RoomImage.load(spec.image)
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
        let host = NSHostingView(rootView: RoomCanvas(image: image, pins: spec.pins,
                                                      front: spec.front, scale: s))
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: w),
            host.heightAnchor.constraint(equalToConstant: h),
        ])
        stack.addArrangedSubview(host)
        if let hint = spec.hint { stack.addArrangedSubview(label(hint, size: 11 * s, kern: 0)) }

        hud.present(minWidth: w + 32 * s)
    }

    private func label(_ text: String, size: CGFloat, kern: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.alignment = .center
        f.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: kern])
        return f
    }
}
