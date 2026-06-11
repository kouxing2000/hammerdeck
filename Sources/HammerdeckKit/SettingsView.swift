import SwiftUI

// The config-and-select surface (Milestone 4 core): feature list with on/off
// toggles, and a per-feature options form GENERATED from the typed manifest
// options. No feature-specific UI code anywhere -- a new plugin gets its form
// for free. Trigger editing (rebind hotkey/schedule/event) is the next step;
// for now the trigger is shown read-only.

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var selectedId: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedId) {
                ForEach(groupedCategories, id: \.self) { category in
                    Section(category.capitalized) {
                        ForEach(store.features.filter { $0.category == category }) { feature in
                            FeatureRow(store: store, feature: feature)
                                .tag(feature.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let id = selectedId, let feature = store.features.first(where: { $0.id == id }) {
                FeatureDetail(store: store, feature: feature)
            } else {
                Text("Select a feature")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            store.refresh()
            if selectedId == nil { selectedId = store.features.first?.id }
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
        // Read fresh values after every write (store bumps optionEpoch).
        .id("\(opt.key)-\(store.optionEpoch)")
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
                ForEach(opt.values, id: \.self) { Text($0).tag($0) }
            }
        case "time":
            LabeledContent(opt.label) {
                TextField("HH:MM", text: timeBinding)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
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
private let allEvents = ["sleep", "wake", "screenLock", "screenUnlock"]

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
        _mode = State(initialValue: m)
        _mods = State(initialValue: Set(t.mods))
        _key = State(initialValue: t.key)
        _follows = State(initialValue: t.follows.joined(separator: " "))
        _everyMin = State(initialValue: t.everyMin ?? 25)
        _at = State(initialValue: t.at ?? "09:00")
        _event = State(initialValue: t.event ?? "wake")
        _conflict = State(initialValue: nil)
    }

    var body: some View {
        Picker("Type", selection: $mode) {
            ForEach(TriggerMode.allCases) { Text($0.label).tag($0) }
        }

        switch mode {
        case .hotkey:
            LabeledContent("Modifiers") {
                HStack(spacing: 4) {
                    ForEach(allMods, id: \.id) { mod in
                        Toggle(mod.symbol, isOn: Binding(
                            get: { mods.contains(mod.id) },
                            set: { on in if on { mods.insert(mod.id) } else { mods.remove(mod.id) } }
                        ))
                        .toggleStyle(.button)
                    }
                }
            }
            LabeledContent("Key") {
                TextField("e.g. j", text: $key)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        case .chord:
            LabeledContent("Prefix modifiers") {
                HStack(spacing: 4) {
                    ForEach(allMods, id: \.id) { mod in
                        Toggle(mod.symbol, isOn: Binding(
                            get: { mods.contains(mod.id) },
                            set: { on in if on { mods.insert(mod.id) } else { mods.remove(mod.id) } }
                        ))
                        .toggleStyle(.button)
                    }
                }
            }
            LabeledContent("Prefix key") {
                TextField("e.g. a", text: $key)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Then keys") {
                TextField("e.g. b c", text: $follows)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }
            Text("Press the prefix, then the follow keys in order (e.g. ⌘⇧A then B).")
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

        HStack {
            Button("Apply") { conflict = store.setTrigger(feature.id, action.id, buildSpec()) }
                .disabled(applyDisabled)
            if action.triggerOverridden {
                Button("Reset to default") {
                    store.clearTrigger(feature.id, action.id)
                    conflict = nil
                }
            }
            Spacer()
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
