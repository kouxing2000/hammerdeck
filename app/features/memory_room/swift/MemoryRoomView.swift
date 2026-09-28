import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Memory Room page -- memory_room's feature-contributed Settings page. The
// user picks the room's picture (one of the built-in rooms, or a photo of a room
// they know). Where each window
// sits is not set here: the room gives a window its spot the first time it sees
// it, and the user drags it in the room itself.
//
// This view owns NO schema. Every read and edit goes through room.lua via
// SettingsStore.readerCall -- decode for display, one op per edit -- and the
// JSON string that comes back is stored verbatim under the same defaults key the
// running feature reads (ctx.getState("room")). Both writers run on the main
// thread and each re-reads the key right before its write, so a window the room
// placed while this page is open is never lost to a stale copy here.
struct MemoryRoomView: View {
    @ObservedObject var store: SettingsStore

    @State private var room = RoomRecord.empty
    @State private var raw = ""
    @State private var notice: String?
    /// The kept photo's filename. Read in load(), never in body: listing a folder
    /// there is main-thread I/O on every render.
    @State private var photo: String?

    static let stateKey = "hammerdeck.state.memory_room.room"
    private static let module = "features.memory_room.room"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                roomCard
            }
            .padding(18)
        }
        .onAppear { load() }
        // The running room writes the same key on every open; follow it so the
        // page never shows (or later writes back) a stale record. The raw-string
        // compare keeps the unrelated defaults traffic from re-decoding anything.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if (UserDefaults.standard.string(forKey: Self.stateKey) ?? "") != raw { load() }
        }
    }

    // MARK: - Data (all through room.lua)

    private func load() {
        raw = UserDefaults.standard.string(forKey: Self.stateKey) ?? ""
        if let dict: [String: Any] = store.callValue(Self.module, "decode", [.string(raw)]) {
            room = RoomRecord(dict)
        }
        // The record's own photo when it names one that is there; the folder only
        // when it names none (a built-in room is showing). A leftover second copy
        // then can never stand in for the photo the room actually uses.
        if let name = room.image, RoomImage.isPhoto(name),
           FileManager.default.fileExists(atPath: RoomImage.url(name).path) {
            photo = name
        } else {
            photo = RoomImage.userPhoto
        }
    }

    /// Run one room.lua edit against the CURRENT stored record and store its result.
    /// Returns the op's status, or nil if the call failed.
    @discardableResult
    private func apply(_ op: String, _ args: [LuaArg]) -> String? {
        let current = UserDefaults.standard.string(forKey: Self.stateKey) ?? ""
        guard let out: [String: Any] = store.callValue(Self.module, op, [.string(current)] + args),
              let json = out["json"] as? String, let status = out["status"] as? String else { return nil }
        UserDefaults.standard.set(json, forKey: Self.stateKey)
        load()
        return status
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.t("memoryRoom.page.title", default: "Memory Room")).font(.title2.weight(.semibold))
            // Only while `open` has a key to press -- which is always, today: it has
            // a default hotkey, is not automatable, and clearing an override
            // restores that default.
            if let key = openShortcut {
                Text(String(format: Strings.t("memoryRoom.page.subtitle",
                                              default: "In an app with many windows, open its room (%@): each window keeps a spot, so you find it by where it is. Click one to bring it forward; drag one to move it."),
                            key))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The room's CURRENT shortcut, drawn as the Settings chip draws it -- never
    /// the default spelled out, which is wrong for anyone who rebound it or does
    /// not use Caps as Hyper. Nil when there is no key to press.
    private var openShortcut: String? {
        guard let action = store.features.first(where: { $0.id == MemoryRoomPage.featureId })?
                .actions.first(where: { $0.id == "open" }),
              let t = action.trigger, t.type == "hotkey" || t.type == "chord"
        else { return nil }
        let glyph = shortcutGlyph(t)
        return glyph.isEmpty ? nil : glyph
    }

    // MARK: - The room

    private var roomCard: some View {
        let image = RoomImage.load(room.image)
        return DashCard(title: Strings.t("memoryRoom.page.room", default: "Room"), icon: "photo", tint: .accentColor) {
            if RoomImage.isPhoto(room.image) && image == nil {
                Label(Strings.t("memoryRoom.page.photoMissing",
                                default: "The room photo is missing. Your windows keep their spots; choose the photo again to see it."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            RoomCanvas(image: image, pins: [])
                .aspectRatio(RoomImage.aspect(image), contentMode: .fit)
                .frame(maxWidth: 760)
            roomPicker
            HStack(spacing: 8) {
                Button(Strings.t("memoryRoom.page.choosePhoto", default: "Choose Photo…")) { choosePhoto() }
                if photo != nil {
                    Button(Strings.t("memoryRoom.page.removePhoto", default: "Remove Photo…")) { removePhoto() }
                }
                Spacer()
            }
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Strings.t("memoryRoom.page.privacy",
                           default: "While your photo is the room in use, it shows whenever the room opens -- including while you share your screen. It stays on this Mac: Hammerdeck keeps its own copy until you remove it or choose another photo."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Which room (built-in rooms + the user's photo)

    /// One tile per built-in room, then the user's photo. Every built-in room has
    /// the same furniture in the same spots, so switching keeps every place and app;
    /// the photo tile switches back to the kept photo, or asks for one.
    ///
    /// Plain rows of four, not a LazyVGrid: eight tiles need no laziness, and a
    /// lazy grid leaves cells it has not scrolled to undrawn (blank in @shot).
    private var roomPicker: some View {
        let onPhoto = RoomImage.isPhoto(room.image)
        let aspect = RoomImage.aspect(RoomImage.load(nil))
        let current = RoomImage.builtinId(room.image)
        var tiles: [RoomTile] = RoomImage.builtins.map { b in
            RoomTile(image: RoomImage.thumbnail(b.id),
                     label: Strings.t("memoryRoom.room.\(b.id)", default: b.name),
                     selected: !onPhoto && current == b.id, aspect: aspect) {
                notice = nil
                // The Study is the record's nil, as it has always been.
                apply("setImage", [.string(b.id == RoomImage.defaultId ? "" : b.id)])
            }
        }
        tiles.append(RoomTile(image: photo.flatMap { RoomImage.thumbnail($0) },
                              label: Strings.t("memoryRoom.page.yourPhoto", default: "Your Photo"),
                              selected: onPhoto, aspect: aspect) {
            notice = nil
            if let photo { apply("setImage", [.string(photo)]) } else { choosePhoto() }
        })
        let perRow = 4
        let rows = stride(from: 0, to: tiles.count, by: perRow).map { Array(tiles[$0..<min($0 + perRow, tiles.count)]) }
        return VStack(spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        rows[r][i].frame(maxWidth: .infinity)
                    }
                    // A short last row keeps the other rows' tile width.
                    ForEach(rows[r].count..<perRow, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
    }

    // MARK: - Photo

    private func choosePhoto() {
        notice = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let img = NSImage(contentsOf: url) else {
            notice = Strings.t("memoryRoom.page.unreadable", default: "Can't open this file as an image. Use JPEG, PNG or HEIC.")
            return
        }
        let px = RoomImage.pixelSize(img)
        let long = max(px.width, px.height), short = max(1, min(px.width, px.height))
        if long < 320 {
            notice = String(format: Strings.t("memoryRoom.page.tooSmall",
                                              default: "This photo is too small (%1$d × %2$d). Use one at least 320 pixels on its long side -- 800 or more looks sharp."),
                            Int(px.width), Int(px.height))
            return
        }
        if long / short > 2.5 {
            notice = Strings.t("memoryRoom.page.tooWide",
                               default: "This photo is very wide or very tall. Crop it first (Preview can do it), then choose it again.")
            return
        }
        if long < 800 {
            let alert = NSAlert()
            alert.messageText = String(format: Strings.t("memoryRoom.page.smallTitle",
                                                         default: "This photo is small (%1$d × %2$d)."),
                                       Int(px.width), Int(px.height))
            alert.informativeText = Strings.t("memoryRoom.page.smallBody", default: "It will look soft in the room.")
            alert.addButton(withTitle: Strings.t("memoryRoom.page.useAnyway", default: "Use Anyway"))
            alert.addButton(withTitle: Strings.t("memoryRoom.page.cancel", default: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // A NEW name every import: RoomImage caches by path, so reusing one name
        // would keep drawing the old photo.
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let name = "\(RoomImage.photoPrefix)\(UUID().uuidString.prefix(8)).\(ext)"
        do {
            try FileManager.default.createDirectory(at: RoomImage.folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: RoomImage.folder.appendingPathComponent(name))
        } catch {
            notice = String(format: Strings.t("memoryRoom.page.copyFailed", default: "Couldn't copy the photo: %@"),
                            error.localizedDescription)
            return
        }
        // Only once the record points at the new copy: deleting the old one first
        // would leave a failed write pointing at a file that no longer exists. Then
        // EVERY other copy goes, not just the one the record named: while a
        // built-in room shows, the record names no photo at all, and the folder
        // must hold exactly one for RoomImage.userPhoto to find.
        if apply("setImage", [.string(name)]) != nil {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: RoomImage.folder.path)) ?? []
            for other in names where other != name { deleteCopy(other) }
        } else {
            deleteCopy(name)
        }
    }

    /// Delete Hammerdeck's copy of the user's photo, once they confirm. The room
    /// leaves the photo FIRST: deleting a file the record still points at would
    /// leave the room drawing its "photo missing" board, and a failed switch must
    /// not cost the user their photo.
    private func removePhoto() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.t("memoryRoom.page.removePhotoTitle", default: "Remove your photo?")
        alert.informativeText = Strings.t("memoryRoom.page.removePhotoBody",
            default: "Hammerdeck deletes its copy of the photo; the original is not touched. If the room is using it, the room switches to the Study -- your windows keep their spots.")
        alert.addButton(withTitle: Strings.t("memoryRoom.page.remove", default: "Remove")).hasDestructiveAction = true
        alert.addButton(withTitle: Strings.t("memoryRoom.page.cancel", default: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notice = nil
        if RoomImage.isPhoto(room.image) {
            guard apply("setImage", [.string("")]) != nil else { return }
        }
        // Every copy, not just the one on the tile: "remove your photo" must leave
        // none behind for userPhoto to bring back.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: RoomImage.folder.path)) ?? []
        for name in names { deleteCopy(name) }
        load()
    }

    /// Delete Hammerdeck's own copy of a photo it no longer uses. Only a name this
    /// page minted (room-*), and only inside the room folder -- never a path the
    /// record could point elsewhere.
    private func deleteCopy(_ name: String?) {
        guard RoomImage.isPhoto(name), let name else { return }
        try? FileManager.default.removeItem(at: RoomImage.folder.appendingPathComponent(name))
    }
}

// MARK: - One room in the picker

private struct RoomTile: View {
    let image: NSImage?
    let label: String
    let selected: Bool
    /// The Study's shape, so every tile lines up whatever a user's photo measures.
    let aspect: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // The picture fills the tile and is cropped to it.
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        } else {
                            // No photo yet: the tile is the way to choose one.
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.6),
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                Image(systemName: "photo.badge.plus")
                                    .font(.title2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 3 : 1))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(5)
                        }
                    }
                Text(label)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The decoded record (display only; room.lua is the schema)

struct RoomRecord {
    let image: String?

    static let empty = RoomRecord(image: nil)

    init(image: String?) { self.image = image }

    init(_ dict: [String: Any]) {
        image = (dict["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
