import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Memory Room editor -- memory_room's feature-contributed Settings page. The
// user picks the room's picture (one of the built-in rooms, or a photo of a room
// they know), clicks it to drop places, drags them, renames them, re-keys them, and
// removes the apps they no longer want there.
//
// This view owns NO schema. Every read and edit goes through room.lua via
// SettingsStore.readerCall -- decode for display, one op per edit -- and the
// JSON string that comes back is stored verbatim under the same defaults key the
// running feature reads (ctx.getState("room")). Both writers run on the main
// thread and each re-reads the key right before its write, so an app placed with
// Shift+letter while this page is open is never lost to a stale copy here.
struct MemoryRoomView: View {
    @ObservedObject var store: SettingsStore

    @State private var room = RoomRecord.empty
    @State private var raw = ""
    @State private var selected: String?
    @State private var drag: (id: String, x: Double, y: Double)?
    @State private var notice: String?
    /// The kept photo's filename. Read in load(), never in body: the room card
    /// re-renders on every drag frame, and listing a folder there is main-thread I/O.
    @State private var photo: String?

    static let stateKey = "hammerdeck.state.memory_room.room"
    private static let module = "features.memory_room.room"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                roomCard
                placesCard
            }
            .padding(18)
        }
        .onAppear { load() }
        // Shift+letter writes the same key from the running feature; follow it so
        // the page never shows (or later writes back) a stale room. The raw-string
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
        if let sel = selected, !room.pins.contains(where: { $0.id == sel }) { selected = nil }
    }

    /// Run one room.lua edit against the CURRENT stored record and store its result.
    /// Returns the op's status (and id, for addPin), or nil if the call failed.
    @discardableResult
    private func apply(_ op: String, _ args: [LuaArg]) -> (status: String, id: String?)? {
        let current = UserDefaults.standard.string(forKey: Self.stateKey) ?? ""
        guard let out: [String: Any] = store.callValue(Self.module, op, [.string(current)] + args),
              let json = out["json"] as? String, let status = out["status"] as? String else { return nil }
        UserDefaults.standard.set(json, forKey: Self.stateKey)
        load()
        return (status, out["id"] as? String)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.t("memoryRoom.page.title", default: "Memory Room")).font(.title2.weight(.semibold))
            // Only while `open` has a key to press -- which is always, today: it has
            // a default hotkey, is not automatable, and clearing an override
            // restores that default.
            if let key = openShortcut {
                Text(String(format: room.showKeys
                            ? Strings.t("memoryRoom.page.subtitle",
                                        default: "Open the room (%@), then press a place's letter to bring its app forward. Shift+letter puts the app in front there.")
                            : Strings.t("memoryRoom.page.subtitleClick",
                                        default: "Open the room (%@), then click a place to bring its app forward. Right-click anywhere in it to put the app you're in there."),
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

    // MARK: - The room (click to add, drag to move)

    private var roomCard: some View {
        let image = RoomImage.load(room.image)
        return DashCard(title: Strings.t("memoryRoom.page.room", default: "Room"), icon: "photo", tint: .accentColor) {
            if RoomImage.isPhoto(room.image) && image == nil {
                Label(Strings.t("memoryRoom.page.photoMissing",
                                default: "The room photo is missing. Your places still work; choose the photo again to see it."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            editor(image)
                .aspectRatio(RoomImage.aspect(image), contentMode: .fit)
                .frame(maxWidth: 760)
            Text(room.showKeys
                 ? Strings.t("memoryRoom.page.editHint",
                             default: "Click an empty spot to add a place; its letter comes from where it sits (top third = QWERT row). Drag a place to move it -- its letter stays.")
                 : Strings.t("memoryRoom.page.editHintClick",
                             default: "Click an empty spot to add a place. Drag a place to move it."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            roomPicker
            VStack(alignment: .leading, spacing: 2) {
                Toggle(Strings.t("memoryRoom.page.showKeys", default: "Show key letters"),
                       isOn: Binding(get: { room.showKeys },
                                     set: { apply("setShowKeys", [.bool($0)]) }))
                Text(Strings.t("memoryRoom.page.showKeysHint",
                               default: "Every place also has a letter: open the room, then press it. Shown or hidden, the letters work."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(Strings.t("memoryRoom.page.choosePhoto", default: "Choose Photo…")) { choosePhoto() }
                if photo != nil {
                    Button(Strings.t("memoryRoom.page.removePhoto", default: "Remove Photo…")) { removePhoto() }
                }
                Spacer()
                Text(String(format: Strings.t("memoryRoom.page.count", default: "%1$d of %2$d places"),
                            room.pins.count, 30))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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

    private func editor(_ image: NSImage?) -> some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoomCanvas(image: image, pins: displayPins(), selected: selected, showKeys: room.showKeys)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in dragChanged(g, size) }
                        .onEnded { g in dragEnded(g, size) })
            }
        }
    }

    /// The pins as drawn, with the one being dragged shown where the pointer is.
    private func displayPins() -> [RoomPinDisplay] {
        room.pins.map { p in
            if let d = drag, d.id == p.id {
                return RoomPinDisplay(id: p.id, key: p.key, name: p.displayName, x: d.x, y: d.y, apps: p.apps)
            }
            return RoomPinDisplay(id: p.id, key: p.key, name: p.displayName, x: p.x, y: p.y, apps: p.apps)
        }
    }

    /// The pin under a point, if any: generous enough to grab the chip, and the
    /// nearest wins when chips crowd.
    private func pinAt(_ pt: CGPoint, _ size: CGSize) -> RoomPinRecord? {
        let hits = room.pins.map { p -> (RoomPinRecord, CGFloat) in
            let dx = p.x * size.width - pt.x, dy = p.y * size.height - pt.y
            return (p, (dx * dx + dy * dy).squareRoot())
        }.filter { $0.1 < 22 }
        return hits.min { $0.1 < $1.1 }?.0
    }

    private func unit(_ pt: CGPoint, _ size: CGSize) -> (Double, Double) {
        (min(1, max(0, pt.x / max(1, size.width))), min(1, max(0, pt.y / max(1, size.height))))
    }

    private func dragChanged(_ g: DragGesture.Value, _ size: CGSize) {
        guard let hit = drag.map({ $0.id }) ?? pinAt(g.startLocation, size)?.id else { return }
        let moved = abs(g.translation.width) + abs(g.translation.height) > 3
        if moved {
            let (x, y) = unit(g.location, size)
            drag = (hit, x, y)
        }
        selected = hit
    }

    private func dragEnded(_ g: DragGesture.Value, _ size: CGSize) {
        defer { drag = nil }
        if let d = drag {                                   // a pin was dragged
            apply("movePin", [.string(d.id), .double(d.x), .double(d.y)])
            return
        }
        if let hit = pinAt(g.startLocation, size) {         // a click on a pin
            selected = hit.id
            return
        }
        let (x, y) = unit(g.location, size)                  // a click on empty room
        notice = nil
        if let r = apply("addPin", [.double(x), .double(y), .string("")]) {
            if r.status == "full" {
                notice = Strings.t("memoryRoom.page.full",
                                   default: "Every letter key is used (30 of 30). Remove a place to add another.")
            } else {
                selected = r.id
            }
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

    // MARK: - Places list

    private var placesCard: some View {
        DashCard(title: Strings.t("memoryRoom.page.places", default: "Places"), icon: "mappin.and.ellipse", tint: .orange) {
            if room.pins.isEmpty {
                Text(Strings.t("memoryRoom.page.noPlaces", default: "No places yet. Click the room to add one."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(room.pins.sorted { keyOrder($0.key) < keyOrder($1.key) }) { pin in
                        PlaceRow(pin: pin, allPins: room.pins, isSelected: pin.id == selected,
                                 onSelect: { selected = pin.id },
                                 onRename: { apply("renamePin", [.string(pin.id), .string($0)]) },
                                 onKey: { apply("setKey", [.string(pin.id), .string($0)]) },
                                 onUnplace: { apply("unplace", [.string(pin.id), .string($0)]) },
                                 onPlace: { placeApp($0, on: pin) },
                                 onRemove: { removePin(pin) })
                    }
                }
                Text(room.showKeys
                     ? Strings.t("memoryRoom.page.placeHint",
                                 default: "To put an app in a place: click + on its row, or open the room over the app and press Shift+the place's letter.")
                     : Strings.t("memoryRoom.page.placeHintClick",
                                 default: "To put an app in a place: click + on its row, or open the room over the app and right-click where you want it."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Put an app picked from the list in `pin`. Same op as Shift+letter, so the
    /// same rules hold: an app lives in one place (picking it here moves it), and a
    /// full place refuses.
    private func placeApp(_ bundleId: String, on pin: RoomPinRecord) {
        let from = room.pins.first { $0.id != pin.id && $0.apps.contains(bundleId) }
        notice = nil
        guard let r = apply("place", [.string(pin.key), .string(bundleId)]) else { return }
        let app = AppCatalog.displayName(forBundleId: bundleId) ?? bundleId
        switch r.status {
        case "moved":
            if let from {
                notice = String(format: Strings.t("memoryRoom.page.movedFrom", default: "%1$@ moved here from %2$@."),
                                app, from.displayName.isEmpty ? from.key.uppercased() : from.displayName)
            }
        case "full":
            notice = Strings.t("memoryRoom.page.placeFull", default: "That place already holds 3 apps. Take one out first.")
        default:
            break
        }
    }

    /// Keyboard order: QWERT row, then ASDF, then ZXCV -- the room read top-down.
    private func keyOrder(_ k: String) -> Int {
        let all = Array("qwertyuiopasdfghjkl;zxcvbnm,./").map(String.init)
        return all.firstIndex(of: k) ?? all.count
    }

    private func removePin(_ pin: RoomPinRecord) {
        if !pin.apps.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(format: Strings.t("memoryRoom.page.removeTitle", default: "Remove %@?"),
                                       pin.displayName.isEmpty ? pin.key.uppercased() : pin.displayName)
            alert.informativeText = Strings.t("memoryRoom.page.removeBody",
                                              default: "The apps placed there lose their place.")
            alert.addButton(withTitle: Strings.t("memoryRoom.page.remove", default: "Remove"))
            alert.addButton(withTitle: Strings.t("memoryRoom.page.cancel", default: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        apply("removePin", [.string(pin.id)])
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
            default: "Hammerdeck deletes its copy of the photo; the original is not touched. If the room is using it, the room switches to the Study -- your places and their apps stay.")
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

// MARK: - One place in the list

private struct PlaceRow: View {
    let pin: RoomPinRecord
    let allPins: [RoomPinRecord]
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onKey: (String) -> Void
    let onUnplace: (String) -> Void
    let onPlace: (String) -> Void
    let onRemove: () -> Void

    @State private var name = ""
    @State private var picking = false
    @FocusState private var editing: Bool

    private static let rows = ["qwertyuiop", "asdfghjkl;", "zxcvbnm,./"]

    var body: some View {
        HStack(spacing: 10) {
            keyMenu
            TextField(Strings.t("memoryRoom.page.namePlaceholder", default: "Name this place"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($editing)
                .onSubmit { commit() }
                .onChange(of: editing) { now in if !now { commit() } }
            HStack(spacing: 4) {
                if pin.apps.isEmpty {
                    Text(Strings.t("memoryRoom.page.empty", default: "empty"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(pin.apps, id: \.self) { app in appChip(app) }
                if pin.apps.count < 3 { addButton }
            }
            Spacer()
            Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(Strings.t("memoryRoom.page.removePlace", default: "Remove this place"))
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onAppear { name = pin.displayName }
        .onChange(of: pin.displayName) { name = $0 }
    }

    private func commit() {
        if name != pin.displayName { onRename(name) }
    }

    /// The keycap: a menu of every letter, showing which place holds each one --
    /// picking a taken letter swaps the two places' keys.
    private var keyMenu: some View {
        Menu {
            ForEach(Self.rows, id: \.self) { row in
                Section {
                    ForEach(Array(row).map(String.init), id: \.self) { k in
                        Button(menuLabel(k)) { onKey(k) }
                    }
                }
            }
        } label: {
            Text(pin.key.uppercased())
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // A fixed column: the menu sizes to its letter (W is wider than I), which
        // would otherwise start every row's name field at a different x.
        .frame(width: 48, alignment: .leading)
        .help(Strings.t("memoryRoom.page.changeKey", default: "Change this place's letter"))
    }

    private func menuLabel(_ k: String) -> String {
        guard let holder = allPins.first(where: { $0.key == k }), holder.id != pin.id else {
            return k.uppercased() + (k == pin.key ? "  ✓" : "")
        }
        let who = holder.displayName.isEmpty ? k.uppercased() : holder.displayName
        return String(format: Strings.t("memoryRoom.page.swapWith", default: "%1$@  (swap with %2$@)"),
                      k.uppercased(), who)
    }

    /// Pick an app from a list: running apps first, type to search every
    /// installed one (the picker the rules editor and App Launcher share).
    private var addButton: some View {
        Button { picking = true } label: { Image(systemName: "plus.circle") }
            .buttonStyle(.borderless)
            .help(Strings.t("memoryRoom.page.addApp", default: "Put an app in this place"))
            .popover(isPresented: $picking) {
                InstalledAppPicker(selectedBundleId: "", onPick: { _, bundleId in
                    picking = false
                    onPlace(bundleId)
                })
                .frame(width: 300)
                .padding(12)
            }
    }

    private func appChip(_ bundleId: String) -> some View {
        HStack(spacing: 3) {
            if let icon = AppCatalog.icon(forBundleId: bundleId) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(AppCatalog.displayName(forBundleId: bundleId)
                 ?? Strings.t("memoryRoom.page.uninstalled", default: "Uninstalled app"))
                .font(.caption)
            Button { onUnplace(bundleId) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(Strings.t("memoryRoom.page.unplace", default: "Take this app out of the place"))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

// MARK: - The decoded record (display only; room.lua is the schema)

struct RoomPinRecord: Identifiable, Equatable {
    let id: String
    let key: String
    let name: String
    let nameKey: String?
    let x: Double
    let y: Double
    let apps: [String]

    /// The default room's names come from the shared catalog, so the page and the
    /// overlay (which localizes the same keys through ctx.t) always agree.
    var displayName: String {
        if let k = nameKey { return Strings.t("memoryRoom.pin.\(k)", default: name) }
        return name
    }
}

struct RoomRecord {
    let image: String?
    let showKeys: Bool
    let pins: [RoomPinRecord]

    static let empty = RoomRecord(image: nil, showKeys: false, pins: [])

    init(image: String?, showKeys: Bool, pins: [RoomPinRecord]) {
        self.image = image; self.showKeys = showKeys; self.pins = pins
    }

    init(_ dict: [String: Any]) {
        image = (dict["image"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        showKeys = dict["showKeys"] as? Bool ?? false
        pins = (dict["pins"] as? [Any] ?? []).compactMap { v in
            guard let d = v as? [String: Any], let id = d["id"] as? String, let key = d["key"] as? String,
                  let x = d["x"] as? Double, let y = d["y"] as? Double else { return nil }
            return RoomPinRecord(id: id, key: key, name: d["name"] as? String ?? "",
                                 nameKey: d["nameKey"] as? String, x: x, y: y,
                                 apps: (d["apps"] as? [Any] ?? []).compactMap { $0 as? String })
        }
    }
}
