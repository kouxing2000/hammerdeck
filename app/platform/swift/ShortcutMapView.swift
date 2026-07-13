import SwiftUI
import AppKit

// The Shortcut Map: a standalone window that shows EVERY feature's shortcut in
// one grouped, in-place-editable grid -- the "see what's used / what's free,
// and rebind without drilling into each plugin" surface. A spreadsheet of
// bindings: one checkbox column per modifier (⌃ ⌥ ⇧ ⌘), an editable / capture
// Key cell, a Then cell (type follow keys to make the row a chord), and a
// Status cell that lights up the conflict tier (green clean /
// amber soft system-or-app collision / red hard in-app conflict).
//
// There is deliberately NO rendered-shortcut column: the mod cells + Key + Then
// ARE the shortcut, so a glyph preview beside them prints the same fact twice.
// Drag-to-swap therefore hangs off the NAME cell -- the row IS the handle --
// rather than off a column that existed only to be dragged.
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

private let kModW: CGFloat = 34
private let kKeyW: CGFloat = 132
private let kThenW: CGFloat = 92
private let kBadgeW: CGFloat = 26
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
            Text(Strings.t("shortcuts.tip", default: "Tip: drag a row's name onto another row to swap the two shortcuts."))
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
            Text(Strings.t("shortcuts.title", default: "Shortcut Map")).font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(Strings.t("shortcuts.filter", default: "Filter"), text: $search).textFieldStyle(.plain).frame(width: 160)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(Strings.t("shortcuts.colFeatureAction", default: "Feature / Action")).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(kMods, id: \.id) { m in
                Text(m.glyph).frame(width: kModW)
            }
            Text(Strings.t("shortcuts.colKey", default: "Key")).frame(width: kKeyW)
            Text(Strings.t("shortcuts.colThen", default: "Then")).frame(width: kThenW)
            // The badge column is glyph-only (💡 / ✏️) -- a header word would say
            // less than the glyphs and their tooltips already do.
            Color.clear.frame(width: kBadgeW, height: 1)
            Text(Strings.t("shortcuts.colStatus", default: "Status")).frame(width: kStatusW, alignment: .leading)
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
            Image(systemName: featureIcon(feature))
                .font(.caption).foregroundStyle(categoryColor(feature.category)).frame(width: 16)
            Text(feature.name).fontWeight(.semibold)
            Text("\(feature.actions.count)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            if !feature.enabled {
                Text(Strings.t("shortcuts.disabled", default: "disabled")).font(.caption2).foregroundStyle(.secondary)
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
                Text(Strings.t("shortcuts.alwaysOnSection", default: "ALWAYS ON -- NO SHORTCUT"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            ForEach(services.filter { matches($0, nil) }) { f in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: featureIcon(f)).foregroundStyle(.secondary).font(.caption)
                            .frame(width: 16)
                        Text(f.name)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(kMods, id: \.id) { _ in Text("").frame(width: kModW) }
                    Text("--").foregroundStyle(.secondary).frame(width: kKeyW)
                    Text("--").foregroundStyle(.secondary).frame(width: kThenW)
                    Color.clear.frame(width: kBadgeW, height: 1)
                    Text(Strings.t("shortcuts.alwaysOnService", default: "always-on service")).foregroundStyle(.secondary)
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
    @State private var follows: String   // chord follow keys (space/comma separated)
    @State private var status: RowStatus
    @State private var capturing = false
    @State private var monitor: Any?
    @State private var isDropTarget = false
    @State private var nameHover = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case key, then }

    /// The grid edits KEYBOARD triggers: a plain hotkey, or a chord (its prefix
    /// in the mod/Key cells, its follow sequence in the Then cell). Schedule and
    /// event triggers aren't keystrokes at all, so they stay read-only here and
    /// are edited in the precise per-feature editor.
    private let editable: Bool

    init(store: SettingsStore, feature: FeatureInfo, action: ActionInfo,
         title: String, indent: CGFloat) {
        self.store = store
        self.feature = feature
        self.action = action
        self.title = title
        self.indent = indent
        let t = action.trigger
        let kind = t?.type
        self.editable = (kind == nil || kind == "hotkey" || kind == "chord")
        _mods = State(initialValue: Set(t?.mods ?? []))
        _key = State(initialValue: t?.key ?? "")
        _follows = State(initialValue: (t?.follows ?? []).joined(separator: " "))
        if let t, !(kind == "hotkey" || kind == "chord") {
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
            thenCell
            badgeCell
            statusCell
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        // Commit on focus loss (clicking away), not only on Enter -- otherwise a
        // typed key/follow-key is shown as OK by the live status recompute but
        // never persisted. apply() is idempotent, so a focus-out with no change
        // is a no-op.
        .onChange(of: focusedField) { f in
            if f == nil { apply() }
        }
        .task(id: "\(editable)|\(mods.sorted().joined())|\(key)|\(follows)") {
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

    /// The name cell is the row's drag handle, and NOTHING else: drag it onto
    /// another row to swap the two shortcuts. It carries exactly one tooltip.
    ///
    /// The binding badges (💡/✏️) deliberately do NOT live here. They explain the
    /// KEY, not the action, so they sit in their own column beside it -- and a
    /// second `.help` in this cell would be blanketed by the drag handle's own
    /// (a cell-wide tooltip rect wins over a child's), which is exactly how the
    /// mnemonic became unreachable once. One cell, one tooltip.
    @ViewBuilder private var nameCell: some View {
        let cell = HStack(spacing: 6) {
            if indent > 0 { Spacer().frame(width: 18) }
            // The handle's slot is reserved on EVERY row, not just swappable ones --
            // a row with no hotkey to trade (a schedule-triggered action, an unbound
            // one) would otherwise start its title 16pt left of its neighbours and
            // ragged the whole column. Reserved always, inked only on hover.
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(swappable && nameHover ? Color.accentColor : .clear)
                .frame(width: 10)
            Text(title)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        if swappable {
            cell
                .draggable("\(feature.id)\t\(action.id)") {
                    let glyph = shortcutGlyph(action.trigger)
                    Text(glyph.isEmpty ? title : glyph).padding(6).background(.thinMaterial)
                }
                // NSCursor.set() (not push/pop): idempotent, so a swap that tears
                // down this row mid-hover -- onHover(false) never fires on the
                // destroyed view -- can't leak a stuck cursor on the stack.
                .onHover { h in
                    nameHover = h
                    (h ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .help(Strings.t("shortcuts.swapHelp", default: "Drag onto another row to swap shortcuts"))
        } else {
            cell
        }
    }

    /// The badge column: what to know about THIS binding, next to the binding.
    /// 💡 = still on its default key, hover for the mnemonic ("why this key").
    /// ✏️ = you've rebound it (the registry drops the mnemonic on override, since
    /// it describes the default choice -- so the two are mutually exclusive).
    /// An action with neither badge (no mnemonic, still on its default) renders the
    /// same empty spacer the header and service rows use -- an EmptyView with a
    /// .frame is not a reliable way to hold a column open, and a row that dropped the
    /// 26pt would shove its Status cell out of line with every other row.
    @ViewBuilder private var badgeCell: some View {
        Group {
            if action.triggerOverridden {
                Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                    .help(Strings.t("shortcuts.customHelp", default: "Custom shortcut (overrides the default)"))
            } else if !action.mnemonic.isEmpty {
                Image(systemName: "lightbulb").font(.caption2).foregroundStyle(.tertiary)
                    .help(action.mnemonic)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(width: kBadgeW)
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
                TextField(capturing ? Strings.t("shortcuts.pressKeys", default: "press keys...") : Strings.t("shortcuts.keyPlaceholder", default: "key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .key)
                    .frame(width: kKeyW - 32)
                    .onSubmit { apply() }
                Button {
                    capturing ? stopCapture() : startCapture()
                } label: {
                    Image(systemName: capturing ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(capturing ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(Strings.t("shortcuts.captureHelp", default: "Capture: click, then press the shortcut"))
            }
            .frame(width: kKeyW)
        } else {
            Text(key.isEmpty ? "--" : key).foregroundStyle(.secondary).frame(width: kKeyW)
        }
    }

    /// The Then cell: optional follow keys. Typing here (e.g. "b c") turns the
    /// row's hotkey prefix into a chord; clearing it makes it a plain hotkey
    /// again -- the type is inferred, no separate picker. Read-only for the
    /// non-keyboard (schedule/event) rows.
    @ViewBuilder private var thenCell: some View {
        if editable {
            TextField(Strings.t("shortcuts.thenPlaceholder", default: "then"), text: $follows)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .then)
                .frame(width: kThenW - 10)
                .onSubmit { apply() }
                .help(Strings.t("shortcuts.thenHelp", default: "Type follow keys (e.g. b c) to make this a chord; leave empty for a plain hotkey"))
                .frame(width: kThenW)
        } else {
            Text(follows.isEmpty ? "--" : follows)
                .foregroundStyle(.secondary).frame(width: kThenW)
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
                Button(Strings.t("shortcuts.reset", default: "Reset")) { reset() }.buttonStyle(.link).font(.caption)
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
        case .ok:              return Strings.t("shortcuts.statusOK", default: "OK")
        case .soft(let s):     return s
        case .hard(let s):     return s
        case .unbound:         return Strings.t("shortcuts.notBound", default: "not bound")
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

    /// Build the row's spec from its live cells. A non-empty Then field makes it
    /// a CHORD (prefix mods+key, then the follow sequence); an empty Then is a
    /// plain hotkey. The grid edits both keyboard trigger types; the type is
    /// inferred so there's no separate picker.
    // Shared with the Settings TriggerEditor (TriggerSpec.keyish): canonical mod
    // order + key casing, follows promoting to a chord -- so the same keystroke
    // persists identically no matter which surface bound it.
    private func buildSpec() -> TriggerSpec {
        TriggerSpec.keyish(mods: mods, key: key, follows: follows)
    }

    /// Apply the current mods+key (+ follow keys = chord) as the trigger. A hard
    /// conflict (registry refusal) shows red and is NOT persisted; a soft
    /// collision shows amber but still binds. An empty key just parks the row as
    /// unbound. Idempotent: if the built spec already matches what's stored
    /// (e.g. a focus-out with no edit), it just refreshes status, no rebind.
    private func apply() {
        guard editable else { return }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { status = .unbound; return }
        let spec = buildSpec()
        let current = store.features.first { $0.id == feature.id }?
            .actions.first { $0.id == action.id }?.trigger
        // No-op if the built spec already matches what's stored. Compare mods as
        // a SET: buildSpec orders them canonically (TriggerSpec.modOrder), but a
        // never-edited default carries them in the feature's declared order, so an
        // ordered == would false-negative and rebind needlessly on a plain focus-out.
        if let current, current.type == spec.type,
           Set(current.mods) == Set(spec.mods),
           current.key == spec.key, current.follows == spec.follows {
            recomputeStatus(); return
        }
        if let reason = store.setTrigger(feature.id, action.id, spec) {
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
        follows = (t?.follows ?? []).joined(separator: " ")
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
        case "chord":    return Strings.t("shortcuts.shortDesc.chord", default: "chord (edit in Settings)")
        case "schedule": return t.everyMin != nil
                            ? String(format: Strings.t("shortcuts.shortDesc.everyMin", default: "every %dm"), t.everyMin!)
                            : String(format: Strings.t("shortcuts.shortDesc.at", default: "at %@"), t.at ?? "")
        case "event":    return String(format: Strings.t("shortcuts.shortDesc.onEvent", default: "on %@"), t.event ?? "")
        default:         return t.type
        }
    }
}
