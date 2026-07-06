// The editor for a `placementList` option (Window Snap's saved placements). A
// user designs a custom window rectangle by clicking two corners on a grid, names
// it, and saves it -- the registry then turns each saved preset into its own
// rebindable Snap action (id "preset_<uuid>"), so a custom placement can be bound
// to a shortcut. Self-contained in window_snap: presets are stored as a JSON array
// of PlacementRow in the feature's own option namespace, and each add/remove/rename
// triggers a feature reload so the bindable action appears/updates live.
//
// Mirrors SiteListEditor's shape (rows + add/remove + JSON persistence); the
// bespoke part is the click-two-corners grid canvas below.

import SwiftUI

// One saved placement. Stored as JSON. Unlike SiteRow, `id` IS persisted -- it is
// the stable key the Lua side derives the action id from ("preset_<id>"), so a
// rename or reorder must keep it. A plain String (not UUID): user presets use a
// generated UUID string, but the seeded recipes use readable ids ("left_third"),
// which a UUID column would reject on decode.
struct PlacementRow: Identifiable, Equatable, Codable {
    var id = UUID().uuidString
    var name = ""
    var x: Double = 0
    var y: Double = 0
    var w: Double = 1
    var h: Double = 1

    enum CodingKeys: String, CodingKey { case id, name, x, y, w, h }

    init() {}
    init(id: String = UUID().uuidString, name: String, x: Double, y: Double, w: Double, h: Double) {
        self.id = id; self.name = name; self.x = x; self.y = y; self.w = w; self.h = h
    }

    // Tolerant decode: a missing key falls back to the property default rather
    // than failing the whole array (mirrors SiteRow -- a hand-edited or partial
    // record must not wipe the list). A missing id is regenerated.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? 1
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? 1
    }

    static func encode(_ rows: [PlacementRow]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(rows), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func decode(_ raw: String) -> [PlacementRow] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let rows = try? JSONDecoder().decode([PlacementRow].self, from: data) else { return [] }
        return rows
    }
}

// The design grid's resolution. Only used while designing; the saved preset
// stores fractions, so it is independent of the fineness it was drawn on. Squares
// (3x3 up to 9x9) plus two oriented grids; finer resolutions let you approximate
// off-half fractions (a 9x9 gives ninths).
private enum Fineness: Int, CaseIterable, Identifiable {
    case g3x3, g4x3, g4x4, g6x4, g6x6, g9x9
    var id: Int { rawValue }
    var cols: Int {
        switch self {
        case .g3x3: return 3; case .g4x3: return 4; case .g4x4: return 4
        case .g6x4: return 6; case .g6x6: return 6; case .g9x9: return 9
        }
    }
    var rows: Int {
        switch self {
        case .g3x3: return 3; case .g4x3: return 3; case .g4x4: return 4
        case .g6x4: return 4; case .g6x6: return 6; case .g9x9: return 9
        }
    }
    var label: String { "\(cols)×\(rows)" }
}

private struct GridCell: Equatable { let col: Int; let row: Int }

// A common-shape starting point. Tapping one appends a normal PlacementRow -- it's
// a SOURCE, not stored data, so there is nothing to seed, mask, or restore.
private struct Shape: Identifiable {
    let id: String
    let en: String       // English default; localized via Strings.t("recipe.<id>")
    let x, y, w, h: Double
    var name: String { Strings.t("recipe.\(id)", default: en) }
}

/// A placement's currently-bound hotkey (empty when unbound). Carried into each
/// row so the shortcut sits WITH the shape -- one place, not a separate screen.
struct SnapCombo: Equatable { var mods: Set<String>; var key: String }

struct PlacementListEditor: View {
    let json: String
    let onChange: (String) -> Void
    let reload: () -> Void
    // The shortcut lives in the row: read the current hotkey for a placement id,
    // and bind/replace it. `bind` returns setTrigger's refusal reason (nil on
    // success) so a rejected combo (e.g. already bound) can be reverted, not shown
    // as a phantom. Wired by SettingsView to the feature's preset action.
    let comboFor: (String) -> SnapCombo
    let bind: (String, Set<String>, String) -> String?

    @State private var rows: [PlacementRow] = []
    @State private var seeded = false

    // Common shapes offered as one-tap chips (thirds/quarters/center the built-in
    // half-snaps don't cover). Fractions; tapping appends a normal, bindable snap.
    private static let shapes: [Shape] = [
        .init(id: "left_third",           en: "Left third",          x: 0,     y: 0,    w: 1.0 / 3, h: 1),
        .init(id: "center_third",         en: "Center third",        x: 1.0/3, y: 0,    w: 1.0 / 3, h: 1),
        .init(id: "right_third",          en: "Right third",         x: 2.0/3, y: 0,    w: 1.0 / 3, h: 1),
        .init(id: "left_two_thirds",      en: "Left two-thirds",     x: 0,     y: 0,    w: 2.0 / 3, h: 1),
        .init(id: "right_two_thirds",     en: "Right two-thirds",    x: 1.0/3, y: 0,    w: 2.0 / 3, h: 1),
        .init(id: "top_left_quarter",     en: "Top-left quarter",    x: 0,     y: 0,    w: 0.5,     h: 0.5),
        .init(id: "top_right_quarter",    en: "Top-right quarter",   x: 0.5,   y: 0,    w: 0.5,     h: 0.5),
        .init(id: "bottom_left_quarter",  en: "Bottom-left quarter", x: 0,     y: 0.5,  w: 0.5,     h: 0.5),
        .init(id: "bottom_right_quarter", en: "Bottom-right quarter",x: 0.5,   y: 0.5,  w: 0.5,     h: 0.5),
        .init(id: "center",               en: "Center",              x: 0.25,  y: 0.25, w: 0.5,     h: 0.5),
    ]

    // The in-progress new placement.
    @State private var fineness: Fineness = .g6x4
    @State private var cornerA: GridCell? = nil
    @State private var cornerB: GridCell? = nil
    @State private var newName = ""
    @State private var nameEdited = false
    @State private var showDesigner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            savedList

            // New snap: tap a common shape, or draw a custom rectangle. No "recipe"
            // jargon -- a shape is just a starting point; each tap adds a normal snap.
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.t("placement.newsnap", default: "New snap"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Self.shapes) { s in
                        Button { addShape(s) } label: {
                            VStack(spacing: 3) {
                                PlacementThumb(x: s.x, y: s.y, w: s.w, h: s.h)
                                    .frame(width: 44, height: 28)
                                Text(s.name).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(String(format: Strings.t("placement.addshape", default: "Add %@"), s.name))
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDesigner.toggle() }
                } label: {
                    Label(showDesigner
                          ? Strings.t("placement.close", default: "Close custom shape")
                          : Strings.t("placement.custom", default: "Custom shape…"),
                          systemImage: showDesigner ? "chevron.up" : "plus")
                }
                .buttonStyle(.borderless).controlSize(.small)
                if showDesigner { addEditor }
            }
        }
        .onAppear { if !seeded { rows = PlacementRow.decode(json); seeded = true } }
        // Reset clears the option -> empty the list. (No seed default, so this is
        // the only external change worth mirroring.)
        .onChange(of: json) { new in
            if new.isEmpty && !rows.isEmpty { rows = [] }
        }
        // Persist any binding-driven edit (a name typed but not yet submitted);
        // structural commits (add/remove) persist AND reload explicitly.
        .onChange(of: rows) { new in
            let encoded = PlacementRow.encode(new)
            if encoded != json { onChange(encoded) }
        }
    }

    private func addShape(_ s: Shape) {
        rows.append(PlacementRow(name: s.name, x: s.x, y: s.y, w: s.w, h: s.h))
        commit()
    }

    // MARK: Saved list

    @ViewBuilder
    private var savedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array($rows.enumerated()), id: \.element.id) { index, $row in
                if index > 0 { Divider() }
                let id = row.id
                PlacementSnapRow(
                    row: $row,
                    combo: comboFor(id),
                    onBind: { m, k in bind(id, m, k) },
                    onDelete: { rows.removeAll { $0.id == id }; commit() },
                    onRename: { commit() }
                )
            }
            if rows.isEmpty {
                Text(Strings.t("placement.empty", default: "No snaps yet -- tap a shape below to add one."))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    // MARK: Add editor (click two corners)

    @ViewBuilder
    private var addEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Full-width so the six resolutions (3x3 .. 9x9) fit without cramping.
            Picker("", selection: $fineness) {
                ForEach(Fineness.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: fineness) { _ in cornerA = nil; cornerB = nil }

            gridCanvas

            // Live preview of the current selection -- a mini-screen showing the
            // exact window shape this placement produces, beside the guidance line.
            HStack(spacing: 10) {
                if let f = currentFractions() {
                    PlacementThumb(x: f.x, y: f.y, w: f.w, h: f.h)
                        .frame(width: 58, height: 36)
                    Text(fractionLabel(f.x, f.y, f.w, f.h))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(cornerA == nil
                     ? Strings.t("placement.pickA", default: "Click a corner, then the opposite corner.")
                     : Strings.t("placement.pickB", default: "Region set -- name it and save, or click again to redo."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField(Strings.t("placement.name", default: "Name"),
                          text: $newName, prompt: Text(Strings.t("placement.name.ph", default: "optional")))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onChange(of: newName) { _ in nameEdited = true }
                Spacer()
                Button {
                    saveNewPreset()
                } label: {
                    Label(Strings.t("placement.save", default: "Save placement"), systemImage: "plus.circle.fill")
                }
                .controlSize(.small)
                .disabled(cornerA == nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.15)))
    }

    private var gridCanvas: some View {
        let cols = fineness.cols, rows = fineness.rows
        return VStack(spacing: 3) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(0..<cols, id: \.self) { c in
                        cellButton(GridCell(col: c, row: r))
                    }
                }
            }
        }
    }

    private func cellButton(_ cell: GridCell) -> some View {
        let inBox = isInBox(cell)
        let isA = cornerA == cell
        let isB = cornerB == cell
        let corner = isA || isB
        return Button {
            tapCell(cell)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(inBox ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(inBox ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: corner ? 2 : 1))
                if isA { cornerTag("A") } else if isB { cornerTag("B") }
            }
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cornerTag(_ s: String) -> some View {
        Text(s).font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
    }

    // MARK: Interaction

    private func tapCell(_ cell: GridCell) {
        // First click sets A; second sets B; a third restarts at a new A. Both
        // corners are explicit clicks, so direction is free (the box is min..max).
        if cornerA == nil || cornerB != nil {
            cornerA = cell; cornerB = nil
        } else {
            cornerB = cell
        }
        syncSuggestedName()
    }

    private func isInBox(_ cell: GridCell) -> Bool {
        guard let a = cornerA else { return false }
        let b = cornerB ?? a
        return cell.col >= min(a.col, b.col) && cell.col <= max(a.col, b.col)
            && cell.row >= min(a.row, b.row) && cell.row <= max(a.row, b.row)
    }

    private func currentFractions() -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let a = cornerA else { return nil }
        let b = cornerB ?? a
        let cols = Double(fineness.cols), rows = Double(fineness.rows)
        let cMin = Double(min(a.col, b.col)), cMax = Double(max(a.col, b.col))
        let rMin = Double(min(a.row, b.row)), rMax = Double(max(a.row, b.row))
        return (cMin / cols, rMin / rows, (cMax - cMin + 1) / cols, (rMax - rMin + 1) / rows)
    }

    private func syncSuggestedName() {
        guard !nameEdited, let f = currentFractions() else { return }
        newName = Self.suggestName(f.x, f.y, f.w, f.h)
    }

    private func saveNewPreset() {
        guard let f = currentFractions() else { return }
        let name = newName.isEmpty ? Self.suggestName(f.x, f.y, f.w, f.h) : newName
        rows.append(PlacementRow(name: name, x: f.x, y: f.y, w: f.w, h: f.h))
        cornerA = nil; cornerB = nil; newName = ""; nameEdited = false
        commit()
    }

    // Persist the current rows AND re-register the feature so the added/removed/
    // renamed preset's bindable action appears/updates live. Persist first (so
    // reload reads the fresh value), then reload.
    private func commit() {
        onChange(PlacementRow.encode(rows))
        reload()
    }

    // MARK: Naming

    /// A human name suggested from the resulting fractions -- covers the common
    /// halves/thirds/quarters/corners; the user can always edit it.
    static func suggestName(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.03 }
        if near(w, 1) && near(h, 1) { return "Full screen" }
        let hPos = near(w, 1) ? "" : near(x, 0) ? "Left" : near(x + w, 1) ? "Right" : "Center"
        let vPos = near(h, 1) ? "" : near(y, 0) ? "Top" : near(y + h, 1) ? "Bottom" : "Middle"
        func frac(_ f: Double) -> String {
            if near(f, 0.5) { return "half" }
            if near(f, 1.0 / 3) { return "third" }
            if near(f, 2.0 / 3) { return "two-thirds" }
            if near(f, 0.25) { return "quarter" }
            if near(f, 0.75) { return "three-quarters" }
            return ""
        }
        // Full-height vertical strip: "<side> <fraction>".
        if near(h, 1) && !hPos.isEmpty {
            let s = frac(w); return s.isEmpty ? "\(hPos) column" : "\(hPos) \(s)"
        }
        // Full-width horizontal strip: "<side> <fraction>".
        if near(w, 1) && !vPos.isEmpty {
            let s = frac(h); return s.isEmpty ? "\(vPos) row" : "\(vPos) \(s)"
        }
        // A corner / quadrant.
        let pos = vPos.isEmpty ? hPos : (hPos.isEmpty ? vPos : "\(vPos)-\(hPos.lowercased())")
        if pos.isEmpty { return "Custom" }
        if near(w, 0.5) && near(h, 0.5) { return "\(pos) quarter" }
        return pos
    }

    private func fractionLabel(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        return "\(pct(w))×\(pct(h))"
    }
}

// One saved snap in the list: the shape thumbnail, an editable name, and its
// shortcut recorded RIGHT HERE -- no trip to a separate Shortcuts screen. Local
// mods/key seed from the bound hotkey and re-seed if it changes externally; a
// capture binds it via onBind.
private struct PlacementSnapRow: View {
    @Binding var row: PlacementRow
    let combo: SnapCombo
    let onBind: (Set<String>, String) -> String?
    let onDelete: () -> Void
    let onRename: () -> Void

    @State private var mods: Set<String> = []
    @State private var key: String = ""
    @State private var conflict: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                PlacementThumb(x: row.x, y: row.y, w: row.w, h: row.h)
                    .frame(width: 42, height: 27)
                TextField(Strings.t("placement.name", default: "Name"), text: $row.name)
                    .textFieldStyle(.plain).labelsHidden()
                    .onSubmit(onRename)
                Spacer(minLength: 6)
                ShortcutRecorder(mods: $mods, key: $key,
                                 placeholder: Strings.t("placement.setkey", default: "Set shortcut")) {
                    // On refusal (e.g. the combo is already bound elsewhere) setTrigger
                    // returns a reason and leaves the binding unchanged -- so revert the
                    // recorder's display to the truth and surface the reason, instead of
                    // showing a phantom shortcut that would never fire this snap.
                    if let reason = onBind(mods, key) {
                        mods = combo.mods; key = combo.key
                        conflict = reason
                    } else {
                        conflict = nil
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(Strings.t("placement.remove", default: "Remove snap"))
            }
            if let conflict {
                Text(conflict).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .onAppear { mods = combo.mods; key = combo.key }
        // An external change (a successful bind refreshes the store, or a reload)
        // re-syncs the recorder to the truth and clears any stale conflict note.
        .onChange(of: combo) { c in mods = c.mods; key = c.key; conflict = nil }
    }
}

// A mini "screen" with the placement's rectangle drawn at its fractions.
private struct PlacementThumb: View {
    let x: Double, y: Double, w: Double, h: Double
    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.85))
                .frame(width: max(2, geo.size.width * w), height: max(2, geo.size.height * h))
                .position(x: geo.size.width * (x + w / 2), y: geo.size.height * (y + h / 2))
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
    }
}
