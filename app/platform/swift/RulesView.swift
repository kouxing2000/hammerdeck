import SwiftUI

// The Rules tab (Automation framework, M1 UI). Lists the automation rules with
// on/off toggles, edit + delete, and a GUIDED add/edit form that builds a rule
// from dropdowns over the trigger + effect types the engine supports. All
// mutation delegates to the tested rules.lua engine via the store -- this view is
// pure presentation, like the generated feature forms.
//
// Trigger types offered here: App-state (frontmost becomes/leaves), System event,
// Schedule. Hotkey/chord rules are authored via each feature's own trigger editor
// (they need the shortcut recorder), so they're intentionally absent from this form.

struct RulesDetail: View {
    @ObservedObject var store: SettingsStore

    // The rule currently being edited (nil = the form is in "add" mode). Lifted
    // here so a row's Edit button can drive the form below it.
    @State private var editing: RuleInfo?

    var body: some View {
        Form {
            Section {
                Text("Rules fire an effect when something happens -- when an app comes "
                     + "to the front, on wake, or on a schedule. Add one below, edit it, "
                     + "toggle it on/off, or delete it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Rules") {
                if store.rules.isEmpty {
                    Label("No rules yet -- add one below.", systemImage: "wand.and.stars")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.rules) { rule in
                        RuleRow(store: store, rule: rule,
                                isEditing: editing?.id == rule.id,
                                onEdit: { editing = rule },
                                onDelete: {
                                    if editing?.id == rule.id { editing = nil }
                                    store.removeRule(rule.id)
                                })
                    }
                }
            }

            AddRuleForm(store: store, editing: $editing)
        }
        .formStyle(.grouped)
        .navigationTitle("Rules")
        .onAppear { store.refreshRules() }
    }
}

private struct RuleRow: View {
    @ObservedObject var store: SettingsStore
    let rule: RuleInfo
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.triggerDesc)
                Text(rule.effectDesc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(isEditing ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Edit this rule")
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { store.setRuleEnabled(rule.id, $0) }
            ))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.vertical, 2)
        .listRowBackground(isEditing ? Color.accentColor.opacity(0.08) : nil)
    }
}

private struct AddRuleForm: View {
    @ObservedObject var store: SettingsStore
    @Binding var editing: RuleInfo?

    @State private var opts = RuleFormOptions([:])
    // Trigger
    @State private var triggerType = "state"      // state | event | schedule
    @State private var signal = "frontmostApp"
    @State private var transition = "becomes"     // becomes | leaves
    @State private var stateValue = ""
    @State private var eventName = "wake"
    @State private var scheduleMode = "everyMin"  // everyMin | at
    @State private var everyMin = 25
    @State private var atTime = "09:00"
    // Effect
    @State private var effectId = "notify"
    @State private var notifyTitle = "Hammerdeck"
    @State private var notifyText = ""
    @State private var formError: String?

    private var isEditing: Bool { editing != nil }

    var body: some View {
        Section(isEditing ? "Edit rule" : "Add a rule") {
            Picker("When", selection: $triggerType) {
                Text("App becomes / leaves frontmost").tag("state")
                Text("System event").tag("event")
                Text("Schedule").tag("schedule")
            }

            switch triggerType {
            case "state":
                Picker("Signal", selection: $signal) {
                    ForEach(opts.signals, id: \.self) { Text($0).tag($0) }
                }
                Picker("Transition", selection: $transition) {
                    Text("becomes").tag("becomes")
                    Text("leaves").tag("leaves")
                }
                HStack {
                    TextField("App name (e.g. Safari)", text: $stateValue)
                    if !candidates.isEmpty {
                        Menu {
                            ForEach(candidates, id: \.self) { c in
                                Button(c) { stateValue = c }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 32)
                        .help("Pick from running apps")
                    }
                }
                if let warning = stateValueWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case "event":
                Picker("Event", selection: $eventName) {
                    ForEach(opts.events, id: \.self) { Text($0).tag($0) }
                }
            case "schedule":
                Picker("Mode", selection: $scheduleMode) {
                    Text("Every N minutes").tag("everyMin")
                    Text("Daily at").tag("at")
                }
                if scheduleMode == "everyMin" {
                    Stepper("Every \(everyMin) min", value: $everyMin, in: 1...1440)
                } else {
                    TextField("HH:MM", text: $atTime)
                }
            default:
                EmptyView()
            }

            Picker("Do", selection: $effectId) {
                ForEach(opts.effects) { e in Text(e.label).tag(e.id) }
            }
            if selectedEffect?.kind == "notify" {
                TextField("Notification title", text: $notifyTitle)
                TextField("Notification text (optional)", text: $notifyText)
            }

            if let formError {
                Label(formError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isEditing {
                    Button("Cancel") { editing = nil }   // onChange resets the form
                }
                Button(isEditing ? "Save changes" : "Add rule") { submit() }
                    .disabled(!canSubmit)
            }
        }
        .onAppear(perform: reloadOptions)
        // Drive the form from the selection: a rule -> pre-fill (edit), nil -> reset (add).
        .onChange(of: editing?.id) { _ in
            if let rule = editing { loadForEdit(rule) } else { resetForm() }
        }
    }

    private var candidates: [String] { opts.signalCandidates[signal] ?? [] }
    private var selectedEffect: RuleEffectOption? { opts.effects.first { $0.id == effectId } }

    /// Warn when the typed value isn't a currently-running app (and we have a
    /// candidate list to compare against). Advisory -- the app may launch later.
    private var stateValueWarning: String? {
        guard triggerType == "state" else { return nil }
        let v = stateValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !candidates.isEmpty, !candidates.contains(v) else { return nil }
        return "\"\(v)\" isn't running now -- the name must match the app exactly "
             + "when it is, or the rule never fires."
    }

    private var canSubmit: Bool {
        if triggerType == "state",
           stateValue.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedEffect?.kind == "notify",
           notifyTitle.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return selectedEffect != nil
    }

    private func reloadOptions() {
        opts = store.ruleFormOptions()
        if signal.isEmpty || !opts.signals.contains(signal) {
            signal = opts.signals.first ?? "frontmostApp"
        }
        if !opts.events.contains(eventName) { eventName = opts.events.first ?? "wake" }
        if !opts.effects.contains(where: { $0.id == effectId }) {
            effectId = opts.effects.first?.id ?? "notify"
        }
    }

    /// Reset every field to add-mode defaults.
    private func resetForm() {
        triggerType = "state"
        signal = opts.signals.first ?? "frontmostApp"
        transition = "becomes"
        stateValue = ""
        eventName = opts.events.first ?? "wake"
        scheduleMode = "everyMin"
        everyMin = 25
        atTime = "09:00"
        effectId = opts.effects.first?.id ?? "notify"
        notifyTitle = "Hammerdeck"
        notifyText = ""
        formError = nil
    }

    /// Reverse of buildSpec: seed the form fields from an existing rule's spec.
    private func loadForEdit(_ rule: RuleInfo) {
        formError = nil
        let on = rule.on
        let type = on["type"] as? String ?? "state"
        triggerType = ["state", "event", "schedule"].contains(type) ? type : "state"
        switch type {
        case "state":
            signal = on["signal"] as? String ?? (opts.signals.first ?? "frontmostApp")
            if let b = on["becomes"] as? String { transition = "becomes"; stateValue = b }
            else if let l = on["leaves"] as? String { transition = "leaves"; stateValue = l }
            else { transition = "becomes"; stateValue = "" }
        case "event":
            eventName = on["event"] as? String ?? "wake"
        case "schedule":
            if let e = on["everyMin"] as? Double { scheduleMode = "everyMin"; everyMin = Int(e) }
            else if let e = on["everyMin"] as? Int { scheduleMode = "everyMin"; everyMin = e }
            else if let a = on["at"] as? String { scheduleMode = "at"; atTime = a }
        default:
            break
        }
        let effect = rule.effect
        if (effect["kind"] as? String) == "command" {
            let f = effect["feature"] as? String ?? ""
            if let a = effect["action"] as? String { effectId = "command:\(f).\(a)" }
            else { effectId = "command:\(f)." }
        } else {
            effectId = "notify"
            notifyTitle = effect["title"] as? String ?? "Hammerdeck"
            notifyText = effect["text"] as? String ?? ""
        }
    }

    private func submit() {
        guard let spec = buildSpec(),
              let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else {
            formError = "could not build the rule"
            return
        }
        let reason = isEditing ? store.updateRule(editing!.id, json) : store.addRule(json)
        if let reason {
            formError = reason
        } else {
            editing = nil      // onChange resets the form back to add mode
            resetForm()
        }
    }

    private func buildSpec() -> [String: Any]? {
        var on: [String: Any]
        switch triggerType {
        case "state":
            let v = stateValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return nil }
            on = ["type": "state", "signal": signal]
            on[transition] = v
        case "event":
            on = ["type": "event", "event": eventName]
        case "schedule":
            on = scheduleMode == "everyMin"
                ? ["type": "schedule", "everyMin": everyMin]
                : ["type": "schedule", "at": atTime]
        default:
            return nil
        }
        guard let eff = selectedEffect else { return nil }
        var effect: [String: Any]
        if eff.kind == "notify" {
            let t = notifyTitle.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            effect = ["kind": "notify", "title": t]
            let body = notifyText.trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { effect["text"] = body }
        } else {
            effect = ["kind": "command", "feature": eff.feature ?? ""]
            if let a = eff.action { effect["action"] = a }
        }
        return ["on": on, "effect": effect]
    }
}
