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
