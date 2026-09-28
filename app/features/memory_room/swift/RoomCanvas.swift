// memory_room's shared drawing: the room picture with one app's windows on it.
// One view serves every place the room appears -- the Hyper+L overlay (RoomPanel),
// the gallery card (MemoryRoomArchetypeScene) and the settings page's picture
// (MemoryRoomView, with no windows) -- so each shows exactly what the user will
// reach for.
//
// The record itself is owned by room.lua; this file only holds the display shape
// (RoomPinDisplay) that the seam decodes into.

import AppKit
import ImageIO
import SwiftUI

/// One window as the room draws it: already resolved.
struct RoomPinDisplay: Identifiable, Equatable {
    let id: String          // room.lua's windowId: what a pick reports back
    let name: String        // the short label under the icon
    let title: String       // the full title, for the hover line
    let x: Double           // 0..1 of the image, top-left origin
    let y: Double
    let apps: [String]      // bundle ids: the app the window belongs to
}

/// Where the room's picture comes from. The record's `image` is one of three kinds:
/// nil (the Study), a built-in room's id, or `room-*` -- a user's photo, held as
/// Hammerdeck's own copy under Application Support so moving or deleting the
/// original never breaks the room. The built-in rooms ship in the feature's
/// assets/rooms (copied into the bundle with the rest of app/).
enum RoomImage {
    static let folderName = "memory_room"
    /// The prefix of every photo copy this app mints: it is what tells a photo
    /// from a built-in id, and the only kind of file the page ever deletes.
    static let photoPrefix = "room-"

    /// The built-in rooms, in the order the picker shows them. Every one draws the
    /// SAME furniture in the SAME spots as the Study, so the default places (and
    /// whatever the user put in them) fit whichever room is chosen.
    static let builtins: [(id: String, file: String, name: String)] = [
        ("study", "study.jpg", "Study"),
        ("midcentury", "midcentury.jpg", "Mid-century"),
        ("nordic", "nordic.jpg", "Nordic"),
        ("japanese", "japanese.jpg", "Japanese"),
        ("neon", "neon.jpg", "Neon"),
        ("nightstudy", "nightstudy.jpg", "Night Study"),
        ("pixel", "pixel.png", "Pixel"),   // PNG: JPEG smears the hard pixel edges
    ]
    static let defaultId = "study"
    static var builtinNameKeys: [String] { builtins.map { "memoryRoom.room.\($0.id)" } }

    static func isPhoto(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix(photoPrefix) && !name.contains("/")
    }

    /// The built-in room a record's `image` shows: an unknown id -- a room a later
    /// version dropped -- falls back to the Study rather than to nothing.
    static func builtinId(_ name: String?) -> String {
        guard let name, builtins.contains(where: { $0.id == name }) else { return defaultId }
        return name
    }

    /// <Application Support>/Hammerdeck/memory_room -- the same root the seam's
    /// data_dir hands Lua, so a user's photo sits beside the rest of the app's data.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Hammerdeck", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func builtinURL(_ id: String) -> URL {
        let file = (builtins.first { $0.id == id } ?? builtins[0]).file   // [0] is the Study
        return URL(fileURLWithPath: resourceRoot())
            .appendingPathComponent("app/features/memory_room/assets/rooms/\(file)")
    }

    /// The file a record's `image` points at: a photo resolves ONLY to its copy in
    /// the folder, so a deleted photo stays missing (the page warns, the canvas
    /// draws a plain board) instead of quietly turning into the Study.
    static func url(_ name: String?) -> URL {
        if let name, isPhoto(name) { return folder.appendingPathComponent(name) }
        return builtinURL(builtinId(name))
    }

    /// The user's kept photo: the one `room-*` file in the folder, whichever room
    /// is showing. The folder, not the record, remembers it, so switching to a
    /// built-in room keeps it; the page holds the folder to ONE such file.
    static var userPhoto: String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { isPhoto($0) }.sorted().first
    }

    // Decoded images are cached by path: the overlay opens on every Hyper+L pause,
    // and re-decoding a multi-megapixel photo each time would put a visible hitch
    // exactly where the room is meant to feel instant. A NEW photo always gets a
    // new filename (MemoryRoomView.choosePhoto), so a path never goes stale.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// The picture for a record's `image` field. Returns nil when a photo's file is
    /// gone -- the caller draws a plain board, because the places are tied to the
    /// pins, not the pixels.
    static func load(_ name: String?) -> NSImage? {
        let url = url(name)
        // A photo can be deleted behind our back; the cache must not keep drawing
        // it (and hiding the page's "photo missing" warning) until a restart.
        if isPhoto(name), !FileManager.default.fileExists(atPath: url.path) { return nil }
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url.path as NSString)
        return img
    }

    /// A picker-tile-sized picture (about 300 px on the long side). ImageIO decodes
    /// straight to that size, so the tile row never holds seven full rooms in memory.
    static func thumbnail(_ name: String?) -> NSImage? {
        let url = url(name)
        if isPhoto(name), !FileManager.default.fileExists(atPath: url.path) { return nil }
        let key = ("thumb:" + url.path) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 300,
              ] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }

    /// Width / height of an image, from its largest bitmap rep (NSImage.size is in
    /// points and can lie for a photo carrying a DPI tag).
    static func aspect(_ img: NSImage?) -> CGFloat {
        guard let img else { return 16.0 / 10.0 }
        let px = pixelSize(img)
        guard px.width > 0, px.height > 0 else { return 16.0 / 10.0 }
        return px.width / px.height
    }

    static func pixelSize(_ img: NSImage) -> CGSize {
        let best = img.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        guard let rep = best, rep.pixelsWide > 0 else { return img.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// A window's picture, shown in a bubble over the room while its icon is hovered.
struct RoomPreview {
    let id: String          // the pin it belongs to
    let image: NSImage
}

/// A window a click in the room can land on (`id` = its RoomPinDisplay id), and
/// where it was drawn: `rect` is in the canvas's own coordinates, top-left origin;
/// its centre is the window's spot.
struct RoomTarget: Equatable {
    let id: String
    let rect: CGRect
    static let space = "roomCanvas"
}

private struct RoomTargetsKey: PreferenceKey {
    static let defaultValue: [RoomTarget] = []
    static func reduce(value: inout [RoomTarget], nextValue: () -> [RoomTarget]) {
        value += nextValue()
    }
}

/// The room at a fixed size: picture (dimmed ~20% so light icons stay readable on
/// any photo), then each window as a dark chip with its app's icon and its short
/// label underneath. `scale` is the caller's HUDScale factor.
struct RoomCanvas: View {
    let image: NSImage?
    let pins: [RoomPinDisplay]
    /// The window in front (by id): its chip gets the accent ring, so the room also
    /// answers "where does the window I'm in right now live?"
    var front: String? = nil
    /// The window under the pointer, or being dragged (by id).
    var selected: String? = nil
    var scale: CGFloat = 1
    /// Draw each window's label (the gallery card leaves them off).
    var showLabels: Bool = true
    /// Where each window was drawn, for a caller that takes clicks (the overlay's
    /// hit layer). Nil draws only.
    var onTargets: (([RoomTarget]) -> Void)? = nil
    /// The hovered window's picture, drawn beside its icon.
    var preview: RoomPreview? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: geo.size.width, height: geo.size.height)
                    Color.black.opacity(0.2)
                } else {
                    // The photo is missing (deleted behind our back): a plain board
                    // keeps every window in the same spot.
                    LinearGradient(colors: [Color(white: 0.20), Color(white: 0.12)],
                                   startPoint: .top, endPoint: .bottom)
                }
                ForEach(pins) { pin in
                    let at = CGPoint(x: pin.x * geo.size.width, y: pin.y * geo.size.height)
                    RoomPinChip(pin: pin, scale: scale,
                                lit: pin.id == front || pin.id == selected,
                                showLabel: showLabels,
                                reportsTargets: onTargets != nil,
                                at: at, room: geo.size)
                        .position(at)
                }
                if let preview, let pin = pins.first(where: { $0.id == preview.id }) {
                    let size = preview.image.size
                    let f = Self.previewFrame(at: CGPoint(x: pin.x * geo.size.width, y: pin.y * geo.size.height),
                                              aspect: size.width / max(1, size.height),
                                              in: geo.size, scale: scale)
                    Image(nsImage: preview.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: f.width, height: f.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
                        .overlay(RoundedRectangle(cornerRadius: 6 * scale)
                            .strokeBorder(.white.opacity(0.85), lineWidth: 1.5 * scale))
                        .shadow(color: .black.opacity(0.5), radius: 8 * scale, y: 3 * scale)
                        .position(x: f.midX, y: f.midY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: RoomTarget.space)
            .onPreferenceChange(RoomTargetsKey.self) { onTargets?($0) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
    }

    /// Where a window dropped at `p` lands: first moved in until its icon and label
    /// (a box of `size` centred there) are inside the room by a few points -- a label
    /// past the edge is drawn slid in or flipped above, off the part that takes
    /// clicks, and the margin absorbs rounding through the stored fractions and a
    /// room drawn a little smaller on another display --
    /// then kept there when it covers no other icon, else the nearest point where
    /// it covers none: rings of growing radius, and on a ring the point furthest
    /// along the way it was sliding off the icon it hit. Where it was moved in to
    /// when the room has no such point. It covers another when its box meets one,
    /// or when the two are closer than `foot` on both axes: room.lua's R.FOOT, as a
    /// fraction of the room, which is what the next open judges two spots by -- a
    /// drop it would call covering is drawn aside there. All else in the room's
    /// points.
    static func landing(for drop: CGPoint, size: CGSize, others: [CGRect],
                        foot: CGSize = .zero, in room: CGSize) -> CGPoint {
        let edge: CGFloat = 4
        guard size.width + 2 * edge <= room.width, size.height + 2 * edge <= room.height else { return drop }
        let p = CGPoint(x: min(max(drop.x, size.width / 2 + edge), room.width - size.width / 2 - edge),
                        y: min(max(drop.y, size.height / 2 + edge), room.height - size.height / 2 - edge))
        let gap: CGFloat = 2
        // A point over the footprint, so rounding through the room's fractions
        // never lands a drop on its edge.
        let reach = CGSize(width: foot.width * room.width + 1, height: foot.height * room.height + 1)
        func box(_ c: CGPoint) -> CGRect {
            CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        }
        func covers(_ o: CGRect, _ c: CGPoint) -> Bool {
            o.intersects(box(c).insetBy(dx: -gap, dy: -gap))
                || (abs(c.x - o.midX) < reach.width && abs(c.y - o.midY) < reach.height)
        }
        let inside = CGRect(origin: .zero, size: room).insetBy(dx: edge - 0.5, dy: edge - 0.5)
        func clear(_ c: CGPoint) -> Bool {
            inside.contains(box(c)) && !others.contains { covers($0, c) }
        }
        guard let hit = others.first(where: { covers($0, p) }) else { return p }
        // Away from the centre of the icon it hit; straight right when dead centre.
        var away = CGVector(dx: p.x - hit.midX, dy: p.y - hit.midY)
        let len = hypot(away.dx, away.dy)
        away = len > 0.5 ? CGVector(dx: away.dx / len, dy: away.dy / len) : CGVector(dx: 1, dy: 0)
        let steps = 32
        for r in stride(from: CGFloat(4), through: max(room.width, room.height), by: 4) {
            let want = CGPoint(x: p.x + away.dx * r, y: p.y + away.dy * r)
            let ring = (0..<steps).map { i -> CGPoint in
                let a = CGFloat(i) / CGFloat(steps) * 2 * .pi
                return CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            }.filter(clear)
            if let best = ring.min(by: { hypot($0.x - want.x, $0.y - want.y) < hypot($1.x - want.x, $1.y - want.y) }) {
                return best
            }
        }
        return p
    }

    /// Where a window's preview goes, for an icon centred at `p` in a room of
    /// `size`: centred over the icon, above it when it fits, else below, else on
    /// whichever side has more room. Always inside the room (the card never
    /// grows), and sized so the larger side can hold it clear of the icon.
    static func previewFrame(at p: CGPoint, aspect: CGFloat, in size: CGSize, scale: CGFloat) -> CGRect {
        let margin = 6 * scale, gap = 6 * scale
        let reach = 22 * scale                          // the icon and its label, from its centre
        let above = p.y - reach - gap - margin          // the height free on each side
        let below = size.height - (p.y + reach + gap) - margin
        var w = size.width * 0.45
        var h = w / max(aspect, 0.1)
        let fit = max(above, below, size.height * 0.3)
        if h > fit { h = fit; w = h * max(aspect, 0.1) }
        let y: CGFloat
        if h <= above { y = p.y - reach - gap - h }
        else if h <= below { y = p.y + reach + gap }
        else if above >= below { y = margin }
        else { y = size.height - margin - h }
        let x = min(max(p.x - w / 2, margin), size.width - margin - w)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A chip with its label under it, like a VStack -- except that the label stays
/// inside the room: near a side it slides in, and at the bottom it goes above the
/// chip, instead of being cut off by the frame. The pin is centred on its spot
/// (`at`, in the room's coordinates), which is how the room is found from here.
private struct PinLayout: Layout {
    let spacing: CGFloat
    let at: CGPoint
    let room: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.map(\.width).max() ?? 0,
                      height: sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let chip = subviews.first else { return }
        let c = chip.sizeThatFits(.unspecified)
        chip.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(c))
        guard subviews.count > 1 else { return }
        let label = subviews[1]
        let l = label.sizeThatFits(.unspecified)
        // The room's edges in these coordinates; with no room given, nothing moves.
        let x: CGFloat
        var y = bounds.minY + c.height + spacing
        if room.width > 0 {
            let minX = bounds.midX - at.x, maxX = minX + room.width
            x = min(max(bounds.midX, minX + l.width / 2), maxX - l.width / 2)
            // A point of slack: a spot stored as a fraction comes back a hair off.
            if y + l.height > bounds.midY - at.y + room.height + 1 { y = bounds.minY - spacing - l.height }
        } else {
            x = bounds.midX
        }
        label.place(at: CGPoint(x: x, y: y), anchor: .top, proposal: ProposedViewSize(l))
    }
}

/// One window: a dark chip with its app's icon, and a short label under it -- every icon in the room is the same
/// app, so the label is what tells two windows apart until their spots do.
struct RoomPinChip: View {
    let pin: RoomPinDisplay
    let scale: CGFloat
    let lit: Bool
    var showLabel: Bool = true
    var reportsTargets: Bool = false
    /// Its spot, and the room's size: the label is kept inside the room.
    var at: CGPoint = .zero
    var room: CGSize = .zero

    var body: some View {
        PinLayout(spacing: 2 * scale, at: at, room: room) {
            chip
            if showLabel, !pin.name.isEmpty {
                // On a dark backing: white text over a bare shadow drops under
                // readable contrast on a bright room or photo.
                Text(pin.name)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4 * scale)
                    .padding(.vertical, 1 * scale)
                    .background(RoundedRectangle(cornerRadius: 4 * scale).fill(Color.black.opacity(0.6)))
            }
        }
        .background(target)
    }

    private var chip: some View {
        HStack(spacing: 3 * scale) {
            ForEach(Array(pin.apps.enumerated()), id: \.offset) { _, app in
                if let icon = AppCatalog.icon(forBundleId: app) {
                    Image(nsImage: icon).resizable().frame(width: 22 * scale, height: 22 * scale)
                } else {
                    RoundedRectangle(cornerRadius: 5 * scale)
                        .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 20 * scale, height: 20 * scale)
                }
            }
        }
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 3 * scale)
        .background(RoundedRectangle(cornerRadius: 7 * scale).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 7 * scale)
            .strokeBorder(lit ? Color.accentColor : .white.opacity(0.35), lineWidth: lit ? 2 * scale : 1))
    }

    /// Report where this window was drawn, for the overlay's hit layer. Nothing at
    /// all when the caller only draws.
    @ViewBuilder private var target: some View {
        if reportsTargets {
            GeometryReader { g in
                Color.clear.preference(key: RoomTargetsKey.self, value: [
                    RoomTarget(id: pin.id, rect: g.frame(in: .named(RoomTarget.space))),
                ])
            }
        }
    }
}
