import SwiftUI

// The config-and-select surface (Milestone 4 core): feature list with on/off
// toggles, and a per-feature options form GENERATED from the typed manifest
// options. No feature-specific UI code anywhere -- a new plugin gets its form
// for free. Trigger editing (rebind hotkey/schedule/event) is the next step;
// for now the trigger is shown read-only.

/// The config-and-select surface, embedded as the Homepage's "Settings" tab: a
/// self-contained two-pane split (feature list + per-feature detail form).
///
/// It uses HSplitView, NOT NavigationSplitView, on purpose: a NavigationSplitView
/// here would render a SECOND sidebar inside the Homepage shell's own split. The
/// plain split nests cleanly in the shell's detail column. Feature selection
/// lives on the store so the Feature Gallery can deep-link a card click straight
/// to a feature's detail (set selectedFeatureId, switch to this tab).
struct SettingsPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        HSplitView {
            List(selection: $store.selectedFeatureId) {
                ForEach(groupedCategories, id: \.self) { category in
                    Section(category.capitalized) {
                        ForEach(store.features.filter { $0.category == category }) { feature in
                            FeatureRow(store: store, feature: feature)
                                .tag(feature.id)
                        }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            Group {
                if let id = store.selectedFeatureId,
                   let feature = store.features.first(where: { $0.id == id }) {
                    FeatureDetail(store: store, feature: feature)
                } else {
                    Text("Select a feature")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.refresh()
            if store.selectedFeatureId == nil { store.selectedFeatureId = store.features.first?.id }
        }
    }

    private var groupedCategories: [String] {
        var seen: [String] = []
        for f in store.features where !seen.contains(f.category) {
            seen.append(f.category)
        }
        return seen
    }
}

private struct FeatureRow: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if feature.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                    Text(feature.name)
                }
                Text(feature.failed ? "Failed to load" : feature.triggerDesc)
                    .font(.caption)
                    .foregroundStyle(feature.failed ? .red : .secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { feature.enabled },
                set: { store.setEnabled(feature.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.kind == "failed")   // a never-registered module can't be toggled
        }
        .padding(.vertical, 2)
    }
}

private struct FeatureDetail: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo

    var body: some View {
        Form {
            if feature.failed {
                Section {
                    Label(
                        feature.errorMessage.isEmpty ? "This feature failed to start." : feature.errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            Section {
                Text(feature.description)
                    .foregroundStyle(.secondary)
                LabeledContent("Trigger", value: feature.triggerDesc)
                LabeledContent("Kind", value: feature.kind == "service" ? "Always-on service" : "Triggered action")
                if !feature.version.isEmpty {
                    LabeledContent("Version", value: feature.version)
                }
            }
            // One trigger editor per declared action (a plugin may have several
            // shortcuts). Pure services have none.
            ForEach(feature.actions) { action in
                Section(feature.actions.count == 1
                        ? "Bind trigger"
                        : "Trigger -- \(action.label)") {
                    TriggerEditor(store: store, feature: feature, action: action)
                        // Remount when the bound trigger changes so local edit
                        // state re-seeds from the new current spec.
                        .id("\(feature.id)|\(action.id)|\(action.triggerDesc)")
                }
            }
            if !feature.options.isEmpty {
                Section("Options") {
                    ForEach(feature.options) { opt in
                        OptionEditor(store: store, featureId: feature.id, opt: opt)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.name)
    }
}

// MARK: - Per-type option editors (the form generator)

private struct OptionEditor: View {
    @ObservedObject var store: SettingsStore
    let featureId: String
    let opt: OptionInfo

    var body: some View {
        HStack {
            editor
            if store.isOptionOverridden(featureId, opt) {
                Button {
                    store.resetOption(featureId, opt)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset to default")
            }
        }
        // NB: do NOT key this view on store.optionEpoch -- the editors read
        // live through their bindings and re-render on @Published changes, so a
        // remount is unneeded AND it steals focus from a TextField/TextEditor on
        // every keystroke (the value write bumps optionEpoch). Stable identity
        // (ForEach keys by opt.key) keeps focus while typing.
    }

    @ViewBuilder
    private var editor: some View {
        switch opt.type {
        case "bool":
            Toggle(opt.label, isOn: Binding(
                get: { store.optionValue(featureId, opt) as? Bool ?? false },
                set: { store.setOptionValue(featureId, opt, $0) }
            ))
        case "int":
            Stepper(value: intBinding, in: intRange) {
                LabeledContent(opt.label, value: "\(intBinding.wrappedValue)")
            }
        case "enum":
            Picker(opt.label, selection: stringBinding) {
                ForEach(opt.values, id: \.self) { Text(opt.enumLabel($0)).tag($0) }
            }
        case "time":
            LabeledContent(opt.label) {
                TextField("HH:MM", text: timeBinding)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        case "string" where opt.multiline:
            VStack(alignment: .leading, spacing: 4) {
                Text(opt.label)
                TextEditor(text: stringBinding)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
        case "string":
            LabeledContent(opt.label) {
                TextField("", text: stringBinding)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.trailing)
            }
        default:
            LabeledContent(opt.label, value: "(\(opt.type) editor not built yet)")
                .foregroundStyle(.secondary)
        }
    }

    private var intBinding: Binding<Int> {
        Binding(
            get: {
                if let d = store.optionValue(featureId, opt) as? Double { return Int(d) }
                return Int(opt.defaultValue as? Double ?? 0)
            },
            set: { store.setOptionValue(featureId, opt, $0) }
        )
    }

    private var intRange: ClosedRange<Int> {
        Int(opt.min ?? 0)...Int(opt.max ?? 9999)
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { store.optionValue(featureId, opt) as? String ?? (opt.defaultValue as? String ?? "") },
            set: { store.setOptionValue(featureId, opt, $0) }
        )
    }

    /// Like stringBinding, but only persists well-formed HH:MM values.
    private var timeBinding: Binding<String> {
        Binding(
            get: { store.optionValue(featureId, opt) as? String ?? (opt.defaultValue as? String ?? "") },
            set: { newValue in
                if newValue.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
                    store.setOptionValue(featureId, opt, newValue)
                }
            }
        )
    }
}

// MARK: - Trigger editor (the rebind picker)

private enum TriggerMode: String, CaseIterable, Identifiable {
    case hotkey, chord, scheduleEvery, scheduleAt, event
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hotkey:        return "Hotkey"
        case .chord:         return "Chord"
        case .scheduleEvery: return "Every N minutes"
        case .scheduleAt:    return "Daily at"
        case .event:         return "System event"
        }
    }
}

private let allMods: [(id: String, symbol: String)] =
    [("cmd", "⌘"), ("alt", "⌥"), ("ctrl", "⌃"), ("shift", "⇧")]
private let allEvents = ["sleep", "wake", "screenLock", "screenUnlock", "screenChanged"]

/// Edits one action's trigger and applies it via registry.setTrigger.
/// Seeded once from action.trigger; remounted by the parent (.id on the bound
/// trigger description) whenever the live binding actually changes.
private struct TriggerEditor: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo
    let action: ActionInfo

    @State private var mode: TriggerMode
    @State private var mods: Set<String>
    @State private var key: String
    @State private var follows: String       // chord: space-separated follow keys
    @State private var everyMin: Int
    @State private var at: String
    @State private var event: String
    @State private var conflict: String?
    @State private var advisories: [String] = []   // soft system/common-app warnings
    @State private var previewHover = false

    // The seeded baseline -- Apply stays disabled until the edit differs from it.
    private let seedMode: TriggerMode
    private let seedMods: Set<String>
    private let seedKey: String
    private let seedFollows: String
    private let seedEveryMin: Int
    private let seedAt: String
    private let seedEvent: String

    init(store: SettingsStore, feature: FeatureInfo, action: ActionInfo) {
        self.store = store
        self.feature = feature
        self.action = action
        let t = action.trigger ?? TriggerSpec()
        let m: TriggerMode
        switch t.type {
        case "chord":    m = .chord
        case "schedule": m = (t.everyMin != nil) ? .scheduleEvery : .scheduleAt
        case "event":    m = .event
        default:         m = .hotkey
        }
        let follows = t.follows.joined(separator: " ")
        _mode = State(initialValue: m)
        _mods = State(initialValue: Set(t.mods))
        _key = State(initialValue: t.key)
        _follows = State(initialValue: follows)
        _everyMin = State(initialValue: t.everyMin ?? 25)
        _at = State(initialValue: t.at ?? "09:00")
        _event = State(initialValue: t.event ?? "wake")
        _conflict = State(initialValue: nil)
        seedMode = m
        seedMods = Set(t.mods)
        seedKey = t.key
        seedFollows = follows
        seedEveryMin = t.everyMin ?? 25
        seedAt = t.at ?? "09:00"
        seedEvent = t.event ?? "wake"
    }

    var body: some View {
        // Action-specific animated preview -- shows what THIS shortcut does
        // (window features map each action to its window move; others fall back
        // to the feature's gallery loop). Plays on hover, like the gallery.
        if FeatureArchetype.hasActionPreview(feature: feature, actionId: action.id) {
            FeatureArchetype.actionScene(feature: feature, actionId: action.id, playing: previewHover)
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .onHover { previewHover = $0 }
        }

        Picker("Type", selection: $mode) {
            ForEach(TriggerMode.allCases) { Text($0.label).tag($0) }
        }

        switch mode {
        case .hotkey:
            LabeledContent("Shortcut") {
                ShortcutRecorder(mods: $mods, key: $key)
            }
        case .chord:
            LabeledContent("Prefix") {
                ShortcutRecorder(mods: $mods, key: $key, placeholder: "Record prefix")
            }
            LabeledContent("Then keys") {
                TextField("e.g. b c", text: $follows)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }
            Text("Record the prefix, then type the follow keys in order (e.g. ⌘⇧A then B).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .scheduleEvery:
            Stepper(value: $everyMin, in: 1...1440) {
                LabeledContent("Interval", value: "\(everyMin) min")
            }
        case .scheduleAt:
            LabeledContent("Daily at") {
                TextField("HH:MM", text: $at)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        case .event:
            Picker("Event", selection: $event) {
                ForEach(allEvents, id: \.self) { Text($0).tag($0) }
            }
        }

        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }

        // Soft, advisory warnings (system / common-app collisions). Unlike a
        // hard conflict these never block Apply -- the user may still want the
        // key; they just see what it costs.
        ForEach(advisories, id: \.self) { warning in
            Label(warning, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }

        HStack {
            Button("Apply") { conflict = store.setTrigger(feature.id, action.id, buildSpec()) }
                .disabled(applyDisabled || !dirty || conflict != nil)
            // Once the edit differs from what's applied, let the user back out
            // in place (discard the unapplied change) without navigating away.
            if dirty {
                Button("Revert") { revertEdit() }
                    .help("Discard the unapplied change and restore the current shortcut")
            }
            if action.triggerOverridden {
                Button("Reset to default") {
                    store.clearTrigger(feature.id, action.id)
                    conflict = nil
                }
            }
            Spacer()
        }
        // Recompute advisories on appear and on every edit (mode/mods/key/
        // follows). store.shortcutAdvisories evals Lua, so debounce by keying
        // on a cheap signature string rather than recomputing each render.
        .task(id: editSignature) { refreshAdvisories() }
    }

    /// A cheap key that changes whenever the candidate binding changes.
    private var editSignature: String {
        "\(mode.rawValue)|\(mods.sorted().joined(separator: "+"))|\(key)|\(follows)"
    }

    private func refreshAdvisories() {
        let isKeyish = (mode == .hotkey || mode == .chord)
        advisories = isKeyish ? store.shortcutAdvisories(buildSpec()) : []
        // Surface a hard in-app conflict LIVE (the moment a taken combo is
        // recorded/typed), not only after Apply -- the recorder now captures
        // such combos instead of firing them, so the warning is how the user
        // learns it's taken. Only for a complete combo; schedule/event keep the
        // Apply-set value.
        if isKeyish {
            conflict = applyDisabled ? nil
                : store.triggerConflict(feature.id, action.id, buildSpec())
        }
    }

    private var applyDisabled: Bool {
        switch mode {
        case .hotkey:     return key.trimmingCharacters(in: .whitespaces).isEmpty
        case .chord:      return key.trimmingCharacters(in: .whitespaces).isEmpty
                              || followKeys.isEmpty
        case .scheduleAt: return at.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) == nil
        default:          return false
        }
    }

    /// True once the edit differs from the seeded baseline -- Apply is grayed
    /// until something actually changes (re-seeds on remount after a successful
    /// apply, so it grays again).
    private var dirty: Bool {
        if mode != seedMode { return true }
        switch mode {
        case .hotkey:
            return mods != seedMods
                || key.trimmingCharacters(in: .whitespaces) != seedKey
        case .chord:
            return mods != seedMods
                || key.trimmingCharacters(in: .whitespaces) != seedKey
                || follows != seedFollows
        case .scheduleEvery: return everyMin != seedEveryMin
        case .scheduleAt:    return at != seedAt
        case .event:         return event != seedEvent
        }
    }

    /// Discard the unapplied edit -- restore every field to the seeded baseline
    /// (the currently-applied trigger). Leaves persistence untouched.
    private func revertEdit() {
        mode = seedMode
        mods = seedMods
        key = seedKey
        follows = seedFollows
        everyMin = seedEveryMin
        at = seedAt
        event = seedEvent
        conflict = nil
    }

    /// The chord follow sequence parsed from the space-separated field.
    private var followKeys: [String] {
        follows.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.lowercased() }
    }

    private func buildSpec() -> TriggerSpec {
        switch mode {
        case .hotkey:
            let ordered = allMods.map(\.id).filter { mods.contains($0) }
            return TriggerSpec(type: "hotkey", mods: ordered,
                               key: key.trimmingCharacters(in: .whitespaces))
        case .chord:
            let ordered = allMods.map(\.id).filter { mods.contains($0) }
            return TriggerSpec(type: "chord", mods: ordered,
                               key: key.trimmingCharacters(in: .whitespaces),
                               follows: followKeys)
        case .scheduleEvery:
            return TriggerSpec(type: "schedule", everyMin: everyMin)
        case .scheduleAt:
            return TriggerSpec(type: "schedule", at: at)
        case .event:
            return TriggerSpec(type: "event", event: event)
        }
    }
}
