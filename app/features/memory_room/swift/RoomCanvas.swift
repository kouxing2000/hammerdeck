// memory_room's shared drawing: the room picture with its pins. One
// view serves all three places the room appears -- the Hyper+L overlay
// (RoomPanel), the Settings editor (MemoryRoomView), and the gallery card
// (MemoryRoomArchetypeScene) -- so a pin can never look different in the editor
// from how it looks when the user reaches for it.
//
// The record itself is owned by room.lua; this file only holds the display shape
// (RoomPinDisplay) that the seam and the page decode into.

import AppKit
import ImageIO
import SwiftUI

/// One place as the room draws it: already localized, already resolved.
struct RoomPinDisplay: Identifiable, Equatable {
    let id: String          // the pin id on the page; the key in the overlay
    let key: String         // one character, drawn upper-cased
    let name: String
    let x: Double           // 0..1 of the image, top-left origin
    let y: Double
    let apps: [String]      // bundle ids, placement order
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

/// Something a click in the room can land on: a place (`app` nil) or one of the
/// app icons in it (`app` = 1-based index into the place's apps). `rect` is in
/// the canvas's own coordinates, top-left origin.
struct RoomTarget: Equatable {
    let key: String
    let app: Int?
    let rect: CGRect
    static let space = "roomCanvas"
}

private struct RoomTargetsKey: PreferenceKey {
    static let defaultValue: [RoomTarget] = []
    static func reduce(value: inout [RoomTarget], nextValue: () -> [RoomTarget]) {
        value += nextValue()
    }
}

/// The room at a fixed size: picture (dimmed ~20% so light pins stay readable on
/// any photo), then each pin as a dark chip with the icons of the apps placed
/// there -- and its key letter, when the room draws letters. `scale` is the
/// caller's HUDScale factor (1 in Settings).
struct RoomCanvas: View {
    let image: NSImage?
    let pins: [RoomPinDisplay]
    /// Bundle id of the frontmost app: its pin gets the accent ring, so the room
    /// also answers "where does the thing I'm in right now live?"
    var front: String? = nil
    /// The pin selected in the editor, or under the pointer in the overlay (by id).
    var selected: String? = nil
    var scale: CGFloat = 1
    /// Draw each place's key letter. Off, a place is its icons (or, empty, a ring).
    var showKeys: Bool = true
    /// Where each place and icon was drawn, for a caller that takes clicks (the
    /// overlay's hit layer). Nil draws only.
    var onTargets: (([RoomTarget]) -> Void)? = nil

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
                    // keeps every place usable in the same spots.
                    LinearGradient(colors: [Color(white: 0.20), Color(white: 0.12)],
                                   startPoint: .top, endPoint: .bottom)
                }
                ForEach(pins) { pin in
                    RoomPinChip(pin: pin, scale: scale,
                                lit: pin.apps.contains { $0 == front } || pin.id == selected,
                                showKey: showKeys,
                                reportsTargets: onTargets != nil)
                        .position(x: pin.x * geo.size.width, y: pin.y * geo.size.height)
                }
            }
            .coordinateSpace(name: RoomTarget.space)
            .onPreferenceChange(RoomTargetsKey.self) { onTargets?($0) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
    }
}

/// One place: a dark chip holding the placed apps' icons, after the key letter
/// when the room draws letters. An empty place with no letter to show is a small
/// dashed ring, so it still reads as a spot to click. No name is drawn: the
/// picture already shows the desk; the name serves the places list and the alerts.
struct RoomPinChip: View {
    let pin: RoomPinDisplay
    let scale: CGFloat
    let lit: Bool
    var showKey: Bool = true
    var reportsTargets: Bool = false

    var body: some View {
        Group {
            if !showKey && pin.apps.isEmpty { ring } else { chip }
        }
        .help(pin.name)
        .background(target(app: nil))
    }

    private var ring: some View {
        Circle()
            .fill(Color.black.opacity(0.55))
            .overlay(Circle().strokeBorder(lit ? Color.accentColor : .white.opacity(0.8),
                                           style: StrokeStyle(lineWidth: (lit ? 2 : 1.5) * scale,
                                                              dash: [3 * scale, 2 * scale])))
            .frame(width: 16 * scale, height: 16 * scale)
    }

    private var chip: some View {
        HStack(spacing: 3 * scale) {
            if showKey {
                Text(pin.key.uppercased())
                    .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 22 * scale, minHeight: 22 * scale)
            }
            ForEach(Array(pin.apps.enumerated()), id: \.element) { i, app in
                Group {
                    if let icon = AppCatalog.icon(forBundleId: app) {
                        Image(nsImage: icon).resizable().frame(width: 22 * scale, height: 22 * scale)
                    } else {
                        // Uninstalled since it was placed: a faded placeholder, so the
                        // place still shows it is taken until the user removes it.
                        RoundedRectangle(cornerRadius: 5 * scale)
                            .strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .frame(width: 20 * scale, height: 20 * scale)
                    }
                }
                .background(target(app: i + 1))
            }
        }
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 3 * scale)
        .background(RoundedRectangle(cornerRadius: 7 * scale).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 7 * scale)
            .strokeBorder(lit ? Color.accentColor : .white.opacity(0.35), lineWidth: lit ? 2 * scale : 1))
    }

    /// Report where this place (or one of its icons) was drawn, for the overlay's
    /// hit layer. Nothing at all when the caller only draws.
    @ViewBuilder private func target(app: Int?) -> some View {
        if reportsTargets {
            GeometryReader { g in
                Color.clear.preference(key: RoomTargetsKey.self, value: [
                    RoomTarget(key: pin.key, app: app, rect: g.frame(in: .named(RoomTarget.space))),
                ])
            }
        }
    }
}
