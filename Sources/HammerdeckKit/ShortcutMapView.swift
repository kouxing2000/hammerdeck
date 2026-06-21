import SwiftUI
import AppKit

// The Shortcut Map: a standalone window that shows EVERY feature's shortcut in
// one grouped, in-place-editable grid -- the "see what's used / what's free,
// and rebind without drilling into each plugin" surface. A spreadsheet of
// bindings: one checkbox column per modifier (⌃ ⌥ ⇧ ⌘), an editable / capture
// Key cell, and a Status cell that lights up the conflict tier (green clean /
// amber soft system-or-app collision / red hard in-app conflict).
//
// A plugin with several actions (e.g. Window Snap's 7) becomes a collapsible
// group header with its actions as indented child rows; single-action plugins
// render as one flat row. Pure services (no rebindable action) sit in a muted
// "Always on -- no shortcut" section.
//
// All edits go through the SAME tested registry path the per-feature editor
// uses (store.setTrigger / clearTrigger / shortcutAdvisories) -- no new model
// logic here, just a denser lens over registry.describe().

// Column order mirrors the left-hand modifier keys on a real Mac keyboard,
// outermost to innermost: ⇧ Shift, ⌃ Control, ⌥ Option, ⌘ Command.
private let kMods: [(id: String, glyph: String)] =
    [("shift", "⇧"), ("ctrl", "⌃"), ("alt", "⌥"), ("cmd", "⌘")]
private let kModOrder = ["shift", "ctrl", "alt", "cmd"]

private let kModW: CGFloat = 34
private let kKeyW: CGFloat = 132
private let kPreviewW: CGFloat = 96
private let kStatusW: CGFloat = 208

// keyGlyph / modGlyphs / shortcutGlyph live in FeatureChrome.swift -- shared
// with the Automation Timeline and Feature Gallery so a trigger renders the
// same everywhere.

struct ShortcutMapView: View {
    @ObservedObject var store: SettingsStore
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            headerRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                    if !services.isEmpty { serviceSection }
                }
            }
            Divider()
            footerHint
        }
        // Embedded in the Homepage shell, which owns the window minimum size.
        .onAppear { store.refresh() }
    }

    private var footerHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
            Text("Tip: drag a shortcut pill onto another row to swap the two bindings.")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: data

    private var bindable: [FeatureInfo] { store.features.filter { !$0.actions.isEmpty && !$0.failed } }
    private var services: [FeatureInfo] { store.features.filter { $0.actions.isEmpty && !$0.failed } }

    private func matches(_ f: FeatureInfo, _ a: ActionInfo?) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        if f.name.lowercased().contains(q) { return true }
        if let a, a.label.lowercased().contains(q) { return true }
        return false
    }

    // MARK: chrome

    private var toolbar: some View {
        HStack {
            Text("Shortcut Map").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $search).textFieldStyle(.plain).frame(width: 160)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Feature / Action").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(kMods, id: \.id) { m in
                Text(m.glyph).frame(width: kModW)
            }
            Text("Key").frame(width: kKeyW)
            Text("Shortcut").frame(width: kPreviewW)
            Text("Status").frame(width: kStatusW, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: rows

    @ViewBuilder private var content: some View {
        ForEach(bindable) { feature in
            let acts = feature.actions.filter { matches(feature, $0) || matches(feature, nil) }
            if !acts.isEmpty {
                if feature.actions.count == 1 {
                    BindingRow(store: store, feature: feature, action: acts[0],
                               title: feature.name, indent: 0)
                        .id(rowID(feature, acts[0]))
                    Divider()
                } else {
                    groupHeader(feature)
                    if !collapsed.contains(feature.id) {
                        ForEach(acts) { a in
                            BindingRow(store: store, feature: feature, action: a,
                                       title: a.label, indent: 1)
                                .id(rowID(feature, a))
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func rowID(_ f: FeatureInfo, _ a: ActionInfo) -> String {
        "\(f.id)|\(a.id)|\(a.triggerDesc)|\(f.enabled)"
    }

    private func groupHeader(_ feature: FeatureInfo) -> some View {
        let isCollapsed = collapsed.contains(feature.id)
        return HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 12)
            Text(feature.name).fontWeight(.semibold)
            Text("\(feature.actions.count)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            if !feature.enabled {
                Text("disabled").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed { collapsed.remove(feature.id) } else { collapsed.insert(feature.id) }
        }
    }

    private var serviceSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ALWAYS ON -- NO SHORTCUT")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(services.filter { matches($0, nil) }) { f in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape").foregroundStyle(.secondary).font(.caption)
                        Text(f.name)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(kMods, id: \.id) { _ in Text("").frame(width: kModW) }
                    Text("--").foregroundStyle(.secondary).frame(width: kKeyW)
                    Text("--").foregroundStyle(.secondary).frame(width: kPreviewW)
                    Text("always-on service").foregroundStyle(.secondary)
                        .frame(width: kStatusW, alignment: .leading)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 5)
                Divider()
            }
        }
    }
}

// MARK: - One binding row (a single rebindable action)

private enum RowStatus {
    case ok
    case soft(String)
    case hard(String)
    case unbound
    case info(String)   // non-hotkey trigger: read-only in the grid
}

private struct BindingRow: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo
    let action: ActionInfo
    let title: String
    let indent: CGFloat

    @State private var mods: Set<String>
    @State private var key: String
    @State private var status: RowStatus
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var isDropTarget = false
    @State private var pillHover = false

    /// The grid edits HOTKEYS. A chord/schedule/event trigger is shown
    /// read-only (its mods/key, where it has them) and routed to the precise
    /// per-feature editor -- the grid would otherwise have to clobber a chord's
    /// follow-sequence to fit one Key cell.
    private let editable: Bool

    init(store: SettingsStore, feature: FeatureInfo, action: ActionInfo,
         title: String, indent: CGFloat) {
        self.store = store
        self.feature = feature
        self.action = action
        self.title = title
        self.indent = indent
        let t = action.trigger
        self.editable = (t == nil || t?.type == "hotkey")
        _mods = State(initialValue: Set(t?.mods ?? []))
        _key = State(initialValue: t?.key ?? "")
        if let t, t.type != "hotkey" {
            _status = State(initialValue: .info(Self.shortDesc(t)))
        } else {
            _status = State(initialValue: .unbound)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            nameCell
            ForEach(kMods, id: \.id) { m in modCell(m.id, m.glyph) }
            keyCell
            previewCell
            statusCell
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        .task(id: "\(editable)|\(mods.sorted().joined())|\(key)") {
            if editable { recomputeStatus() }
        }
        .onDisappear { stopCapture() }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { hovering in
            isDropTarget = hovering && swappable
        }
    }

    /// A row carries a swappable shortcut only when it's an editable hotkey with
    /// a key set -- drag-to-swap trades two concrete hotkeys.
    private var swappable: Bool {
        editable && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Shortcut column: a compact glyph that doubles as the drag handle.
    /// Drag it onto another swappable row to exchange the two shortcuts.
    @ViewBuilder private var previewCell: some View {
        let glyph = shortcutGlyph(action.trigger)
        let label = glyph.isEmpty ? "--" : glyph
        Group {
            if swappable {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(pillHover ? Color.accentColor : .secondary)
                    Text(label)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(pillHover ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(pillHover ? Color.accentColor.opacity(0.5) : .secondary.opacity(0.25)))
                .shadow(color: .black.opacity(pillHover ? 0.18 : 0), radius: 2, y: 1)
                .draggable("\(feature.id)\t\(action.id)") {
                    Text(label).padding(6).background(.thinMaterial)
                }
                // NSCursor.set() (not push/pop): idempotent, so a swap that
                // tears down this row mid-hover -- onHover(false) never fires on
                // the destroyed view -- can't leak a stuck cursor onto the stack.
                .onHover { h in
                    pillHover = h
                    if h { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                }
                .help("Drag onto another row to swap shortcuts")
            } else {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: kPreviewW)
    }

    /// A dropped row id ("featureId\tactionId") swaps that action's shortcut
    /// with this row's. Ignores a drop onto itself or onto a non-swappable row.
    private func handleDrop(_ items: [String]) -> Bool {
        guard swappable, let payload = items.first else { return false }
        let parts = payload.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let (srcId, srcAction) = (parts[0], parts[1])
        if srcId == feature.id && srcAction == action.id { return false }
        store.swapTriggers(srcId, srcAction, feature.id, action.id)
        return true
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            if indent > 0 { Spacer().frame(width: 18) }
            Text(title)
            if action.triggerOverridden {
                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                    .help("Custom shortcut (overrides the default)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A modifier cell rendered as the modifier GLYPH: filled-blue with the
    /// white glyph when on, an empty square when off (matches the table mockup).
    /// Toggling applies the new combo immediately.
    private func modCell(_ id: String, _ glyph: String) -> some View {
        let on = mods.contains(id)
        return Button {
            if on { mods.remove(id) } else { mods.insert(id) }
            apply()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(on ? Color.accentColor : Color.gray.opacity(0.12))
                if !on {
                    RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.35), lineWidth: 1)
                }
                if on {
                    Text(glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .frame(width: kModW)
    }

    @ViewBuilder private var keyCell: some View {
        if editable {
            HStack(spacing: 4) {
                TextField(capturing ? "press keys..." : "key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: kKeyW - 32)
                    .onSubmit { apply() }
                Button {
                    capturing ? stopCapture() : startCapture()
                } label: {
                    Image(systemName: capturing ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(capturing ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help("Capture: click, then press the shortcut")
            }
            .frame(width: kKeyW)
        } else {
            Text(key.isEmpty ? "--" : key).foregroundStyle(.secondary).frame(width: kKeyW)
        }
    }

    private var statusCell: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(statusIsError ? .primary : .secondary)
                .help(statusText)
            Spacer()
            if action.triggerOverridden && editable {
                Button("Reset") { reset() }.buttonStyle(.link).font(.caption)
            }
        }
        .font(.caption)
        .frame(width: kStatusW, alignment: .leading)
    }

    // MARK: status

    private var statusColor: Color {
        switch status {
        case .ok:        return .green
        case .soft:      return .orange
        case .hard:      return .red
        case .unbound:   return .gray.opacity(0.5)
        case .info:      return .gray.opacity(0.5)
        }
    }
    private var statusText: String {
        switch status {
        case .ok:              return "OK"
        case .soft(let s):     return s
        case .hard(let s):     return s
        case .unbound:         return "not bound"
        case .info(let s):     return s
        }
    }
    private var statusIsError: Bool {
        if case .hard = status { return true }
        return false
    }

    private func recomputeStatus() {
        guard editable else { return }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { status = .unbound; return }
        let spec = buildSpec()
        // Hard (in-app) conflict wins -- otherwise the .task recompute would
        // clobber a rejected binding's red status back to green, since
        // advisories only cover soft system/common-app collisions.
        if let reason = store.triggerConflict(feature.id, action.id, spec) {
            status = .hard(reason)
            return
        }
        let adv = store.shortcutAdvisories(spec)
        status = adv.isEmpty ? .ok : .soft(adv.joined(separator: " · "))
    }

    // MARK: editing

    private func buildSpec() -> TriggerSpec {
        let ordered = kModOrder.filter { mods.contains($0) }
        return TriggerSpec(type: "hotkey", mods: ordered,
                           key: key.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Apply the current mods+key as a hotkey. A hard conflict (registry
    /// refusal) shows red and is NOT persisted; a soft collision shows amber but
    /// still binds. An empty key just parks the row as unbound.
    private func apply() {
        guard editable else { return }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { status = .unbound; return }
        if let reason = store.setTrigger(feature.id, action.id, buildSpec()) {
            status = .hard(reason)
        } else {
            recomputeStatus()
        }
    }

    private func reset() {
        store.clearTrigger(feature.id, action.id)
        let t = store.features.first { $0.id == feature.id }?
            .actions.first { $0.id == action.id }?.trigger
        mods = Set(t?.mods ?? [])
        key = t?.key ?? ""
        recomputeStatus()
    }

    // MARK: keystroke capture

    private func startCapture() {
        capturing = true
        monitor = ShortcutCapture.begin(onKey: { m, name in
            mods = m
            key = name
            stopCapture()
            apply()
        }, onCancel: { stopCapture() })
    }

    private func stopCapture() {
        ShortcutCapture.end(monitor)
        monitor = nil
        capturing = false
    }

    static func shortDesc(_ t: TriggerSpec) -> String {
        switch t.type {
        case "chord":    return "chord (edit in Settings)"
        case "schedule": return t.everyMin != nil ? "every \(t.everyMin!)m" : "at \(t.at ?? "")"
        case "event":    return "on \(t.event ?? "")"
        default:         return t.type
        }
    }
}
