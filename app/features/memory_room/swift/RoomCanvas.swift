// memory_room's shared drawing: the room picture with its key-lettered pins. One
// view serves all three places the room appears -- the Hyper+L overlay
// (RoomPanel), the Settings editor (MemoryRoomView), and the gallery card
// (MemoryRoomArchetypeScene) -- so a pin can never look different in the editor
// from how it looks when the user reaches for it.
//
// The record itself is owned by room.lua; this file only holds the display shape
// (RoomPinDisplay) that the seam and the page decode into.

import AppKit
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

/// Where the room's picture comes from. The default room ships in the feature's
/// assets/ (copied into the bundle with the rest of app/); a user's photo is
/// Hammerdeck's own copy under Application Support, so moving or deleting the
/// original never breaks the room.
enum RoomImage {
    static let folderName = "memory_room"

    /// <Application Support>/Hammerdeck/memory_room -- the same root the seam's
    /// data_dir hands Lua, so a user's photo sits beside the rest of the app's data.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Hammerdeck", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: resourceRoot())
            .appendingPathComponent("app/features/memory_room/assets/default_room.jpg")
    }

    // Decoded images are cached by path: the overlay opens on every Hyper+L pause,
    // and re-decoding a multi-megapixel photo each time would put a visible hitch
    // exactly where the room is meant to feel instant. A NEW photo always gets a
    // new filename (MemoryRoomView.importPhoto), so a path never goes stale.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    /// The picture for a record's `image` field: nil = the default room. Returns
    /// nil when the file is gone -- the caller draws a plain board, because the
    /// places are tied to the pins, not the pixels.
    static func load(_ name: String?) -> NSImage? {
        let url = name.map { folder.appendingPathComponent($0) } ?? defaultURL
        if let hit = cache.object(forKey: url.path as NSString) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url.path as NSString)
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

/// The room at a fixed size: picture (dimmed ~20% so light pins stay readable on
/// any photo), then each pin as a dark keycap chip with the icons of the apps
/// placed there. `scale` is the caller's HUDScale factor (1 in Settings).
struct RoomCanvas: View {
    let image: NSImage?
    let pins: [RoomPinDisplay]
    /// Bundle id of the frontmost app: its pin gets the accent ring, so the room
    /// also answers "where does the thing I'm in right now live?"
    var front: String? = nil
    /// The pin selected in the editor (by id).
    var selected: String? = nil
    var scale: CGFloat = 1
    /// Caption each chip with its place's name -- how a newcomer learns the room.
    var showNames: Bool = true

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
                                showName: showNames)
                        .position(x: pin.x * geo.size.width, y: pin.y * geo.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
    }
}

/// One place: the key letter on a dark chip, the placed apps' icons beside it.
struct RoomPinChip: View {
    let pin: RoomPinDisplay
    let scale: CGFloat
    let lit: Bool
    var showName: Bool = true

    var body: some View {
        VStack(spacing: 2 * scale) {
            chip
            if showName, !pin.name.isEmpty {
                Text(pin.name)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2 * scale)
                    .lineLimit(1)
            }
        }
        .help(pin.name)
    }

    private var chip: some View {
        HStack(spacing: 3 * scale) {
            Text(pin.key.uppercased())
                .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 22 * scale, minHeight: 22 * scale)
            ForEach(pin.apps, id: \.self) { app in
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
        }
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 3 * scale)
        .background(RoundedRectangle(cornerRadius: 7 * scale).fill(Color.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 7 * scale)
            .strokeBorder(lit ? Color.accentColor : .white.opacity(0.35), lineWidth: lit ? 2 * scale : 1))
    }
}
