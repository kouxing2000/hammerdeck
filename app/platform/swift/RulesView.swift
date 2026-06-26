import SwiftUI

// The Rules page (Automation framework). A first-class automation manager in the
// home shell -- a peer of the Shortcut Map / Timeline, NOT a Settings row, since
// rules span features. MASTER-DETAIL: the rule list on the left, a GUIDED add/edit
// form on the right that builds a rule from dropdowns over the trigger + effect
// types the engine supports. All mutation delegates to the tested rules.lua engine
// via the store -- this view is pure presentation, like the generated feature forms.
//
// Trigger types offered here: App-state (frontmost becomes/leaves), System event,
// Schedule. Hotkey/chord rules are authored via each feature's own trigger editor
// (they need the shortcut recorder), so they're intentionally absent from this form.

struct RulesPageView: View {
    @ObservedObject var store: SettingsStore

    // The single source of truth: nil = the form is in "add" mode (the "New rule"
    // row is selected); a RuleInfo = editing that rule. The list selection is a
    // pure function of this, so the two never drift.
    @State private var editing: RuleInfo?

    private let newRowId = "__new__"

    var body: some View {
        HSplitView {
            ruleList
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Uses HSplitView (not a nested NavigationSplitView) so it docks in the
        // home shell's detail column -- the same pattern as SettingsPane.
        .onAppear { store.refreshRules() }
    }

    // List selection derived from `editing` (one source of truth): the rule's id,
    // or the "New rule" sentinel when adding.
    private var selection: Binding<String?> {
        Binding(
            get: { editing?.id ?? newRowId },
            set: { row in
                editing = (row == nil || row == newRowId)
                    ? nil : store.rules.first { $0.id == row }
            })
    }

    private var ruleList: some View {
        List(selection: selection) {
            Section {
                Label("New rule", systemImage: "plus.circle.fill")
                    .foregroundStyle(.tint).tag(newRowId)
            }
            Section("Rules (\(store.rules.count))") {
                if store.rules.isEmpty {
                    Text("No rules yet -- pick \"New rule\" to add one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.rules) { rule in
                        RulePageRow(store: store, rule: rule,
                                    onDelete: {
                                        if editing?.id == rule.id { editing = nil }
                                        store.removeRule(rule.id)
                                    })
                            .tag(rule.id)
                    }
                }
            }
        }
    }

    private var detail: some View {
        Form {
            Section {
                Text("Rules fire an effect when something happens -- an app comes to the "
                     + "front, a display connects, on wake, or on a schedule. Pick a rule to "
                     + "edit it, or \"New rule\" to add one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AddRuleForm(store: store, editing: $editing)
        }
        .formStyle(.grouped)
        // Cap the form at a readable column width so it doesn't sprawl edge-to-edge
        // (labels flush-left, values flung to the far-right) in a wide window; the
        // outer frame centers that column and lets the rest be margin.
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .center)
        .navigationTitle("Rules")
    }
}

// One row in the rule list: trigger -> effect, an on/off toggle, and delete.
// Selecting the row (anywhere else) opens it in the detail editor -- no separate
// pencil affordance, the selection IS the edit.
private struct RulePageRow: View {
    @ObservedObject var store: SettingsStore
    let rule: RuleInfo
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.triggerDesc).font(.callout).lineLimit(1)
                Text(rule.effectDesc).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { rule.enabled },
                                     set: { store.setRuleEnabled(rule.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(rule.enabled ? "Enabled" : "Disabled")
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).help("Delete this rule")
        }
        .padding(.vertical, 2)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// One window-placement row in the layout editor: an app, a target display, and
/// a position. The position is either a named snap-grid id, or -- when the row
/// came from "Capture current layout" -- exact ratios (`ratios` non-nil, `pos`
/// holds the captured sentinel so the picker can show it as "Captured").
private struct Placement: Identifiable {
    let id = UUID()
    var app: String = ""
    var screen: String = ""
    var pos: String = "full"
    var ratios: [String: Double]? = nil
}
private let capturedPosId = "__captured__"

private struct AddRuleForm: View {
    @ObservedObject var store: SettingsStore
    @Binding var editing: RuleInfo?

    @State private var opts = RuleFormOptions([:])
    // Trigger. triggerType is "state:<signal>" | "event" | "schedule" -- the chosen
    // "When" IS the signal (Frontmost app / Connected display), so there is no
    // separate Signal sub-picker; each state signal is its own top-level choice.
    @State private var triggerType = "state:frontmostApp"
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
    @State private var placements: [Placement] = []   // the layout effect's rows
    @State private var shortcutName = ""              // runShortcut
    @State private var openURLValue = ""              // openURL
    @State private var formError: String?
    // Advanced "Edit as JSON" mode: one rule, one JSON spec.
    @State private var advanced = false
    @State private var jsonText = ""
    @State private var jsonSeed = ""            // what jsonText was seeded with (dirty check)
    @State private var confirmLeaveJSON = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        Section(isEditing ? "Edit rule" : "Add a rule") {
            // Form is the default; JSON (advanced) edits the rule's full spec --
            // the escape hatch for what the guided form can't express (e.g. a
            // placement's titlePattern). One rule, one JSON. The binding GUARDS
            // the JSON->Form switch when the editor is dirty, so a mis-tap can't
            // silently throw away typed JSON.
            Picker("Edit mode", selection: modeBinding) {
                Text("Form").tag(false)
                Text("JSON (advanced)").tag(true)
            }
            .pickerStyle(.segmented)
            .confirmationDialog("Discard your JSON edits?",
                                isPresented: $confirmLeaveJSON, titleVisibility: .visible) {
                Button("Discard edits", role: .destructive) { advanced = false }
                Button("Keep editing JSON", role: .cancel) {}
            } message: {
                Text("Switching to the form discards the changes you made in the JSON editor.")
            }

            if advanced {
                jsonEditor
            } else {
            Picker("When", selection: $triggerType) {
                // Each state signal is its own top-level choice (Frontmost app,
                // Connected display, ...) -- no nested "Signal" picker.
                ForEach(opts.signals, id: \.self) { sig in
                    Text(signalLabel(sig)).tag("state:" + sig)
                }
                Text("System event").tag("event")
                Text("Schedule").tag("schedule")
            }

            if isStateTrigger {
                Picker("Transition", selection: $transition) {
                    Text(meta?.enterVerb ?? "becomes").tag("becomes")
                    Text(meta?.leaveVerb ?? "leaves").tag("leaves")
                }
                HStack {
                    TextField(valuePlaceholder, text: $stateValue)
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
                        .help("Pick a suggested value")
                    }
                }
                if let warning = stateValueWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if triggerType == "event" {
                Picker("Event", selection: $eventName) {
                    ForEach(opts.events, id: \.self) { Text($0).tag($0) }
                }
            } else if triggerType == "schedule" {
                Picker("Mode", selection: $scheduleMode) {
                    Text("Every N minutes").tag("everyMin")
                    Text("Daily at").tag("at")
                }
                if scheduleMode == "everyMin" {
                    Stepper("Every \(everyMin) min", value: $everyMin, in: 1...1440)
                } else {
                    TextField("HH:MM", text: $atTime)
                }
            }

            Picker("Do", selection: $effectId) {
                ForEach(opts.effects) { e in Text(e.label).tag(e.id) }
            }
            if selectedEffect?.kind == "notify" {
                TextField("Notification title", text: $notifyTitle)
                TextField("Notification text (optional)", text: $notifyText)
            } else if selectedEffect?.kind == "layout" {
                layoutEditor
            } else if selectedEffect?.kind == "runShortcut" {
                TextField("Shortcut name (exactly as in the Shortcuts app)", text: $shortcutName)
                Text("Runs a macOS Shortcut -- the escape hatch to Focus/DND, volume, "
                     + "HomeKit, and anything Shortcuts can do.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if selectedEffect?.kind == "openURL" {
                TextField("URL (https://… , or an app scheme like raycast://…)", text: $openURLValue)
            }
            }   // end of the Form-mode (!advanced) fields

            if let formError {
                Label(formError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isEditing {
                    Button("Cancel") { editing = nil }   // onChange resets the form
                }
                Button(isEditing ? "Save changes" : "Add rule") {
                    advanced ? submitJSON() : submit()
                }
                .disabled(!canSubmit)
            }
        }
        .onAppear(perform: reloadOptions)
        // Entering JSON mode seeds the editor with the rule's current spec and
        // records that seed (so the toggle binding can tell if it was edited).
        .onChange(of: advanced) { on in
            if on { jsonText = currentSpecJSON(); jsonSeed = jsonText }
        }
        // Drive the form from the selection: a rule -> pre-fill (edit), nil -> reset (add).
        .onChange(of: editing?.id) { _ in
            if let rule = editing { loadForEdit(rule) } else { resetForm() }
        }
        // Seed a first placement row when the user switches the effect to "layout".
        .onChange(of: effectId) { _ in
            if selectedEffect?.kind == "layout" && placements.isEmpty { addPlacement() }
        }
    }

    // The advanced raw-JSON editor for one rule's full spec. Saving validates
    // through the same engine path as the form (addJSON / updateJSON), so a bad
    // spec comes back as an inline error, never a crash.
    @ViewBuilder private var jsonEditor: some View {
        Text("Edit this rule's full spec as JSON -- this reaches what the form can't. "
             + "Each layout window shows a \"titlePattern\": fill it with part of a "
             + "window's title (case-insensitive) to target one of several same-app "
             + "windows (leave \"\" to match any). Saving validates the spec.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        TextEditor(text: $jsonText)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 220)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.3)))
            .autocorrectionDisabled()
    }

    // The repeatable window-placement editor (shown when the effect is "layout").
    @ViewBuilder private var layoutEditor: some View {
        if placements.isEmpty {
            Text("No windows yet -- add one, or capture your current arrangement.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(placements.enumerated()), id: \.element.id) { i, p in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("App (e.g. Safari)", text: $placements[i].app)
                    if !appCandidates.isEmpty {
                        Menu {
                            ForEach(appCandidates, id: \.self) { a in
                                Button(a) { placements[i].app = a }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).frame(width: 30)
                        .help("Pick from running apps")
                    }
                    Button(role: .destructive) {
                        placements.removeAll { $0.id == p.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this window")
                }
                // Stacked (not side-by-side) so a long display name never forces a
                // wider pane -- the row reflows to whatever width it's given.
                Picker("Display", selection: $placements[i].screen) {
                    ForEach(displayOptions(p.screen), id: \.self) { Text($0).tag($0) }
                }
                Picker("Position", selection: $placements[i].pos) {
                    if p.ratios != nil { Text("Captured").tag(capturedPosId) }
                    ForEach(opts.layoutPositions) { Text($0.label).tag($0.id) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        }
        HStack {
            Button { addPlacement() } label: { Label("Add window", systemImage: "plus") }
            Spacer()
            Button { capture() } label: {
                Label("Capture current layout", systemImage: "camera.viewfinder")
            }
            .help("Snapshot where your windows are arranged right now")
        }
    }

    // Guards the Form/JSON toggle: switching JSON->Form while the editor is dirty
    // (jsonText differs from its seed) asks first, so a mis-tap never silently
    // discards typed JSON. Every other transition switches immediately.
    private var modeBinding: Binding<Bool> {
        Binding(
            get: { advanced },
            set: { wantAdvanced in
                if advanced && !wantAdvanced && jsonText != jsonSeed {
                    confirmLeaveJSON = true     // dirty JSON -> confirm before leaving
                } else {
                    advanced = wantAdvanced
                }
            })
    }

    // The "When" choice encodes the signal as "state:<signal>"; these unpack it.
    private var isStateTrigger: Bool { triggerType.hasPrefix("state:") }
    private var signal: String {
        isStateTrigger ? String(triggerType.dropFirst("state:".count)) : ""
    }

    private var candidates: [String] { opts.signalCandidates[signal] ?? [] }
    private var selectedEffect: RuleEffectOption? { opts.effects.first { $0.id == effectId } }

    // Per-signal UI metadata from signals.lua (label, value noun, transition
    // verbs) -- so the form renders ANY signal with zero per-signal Swift code.
    private var meta: SignalMeta? { opts.signalMeta[signal] }
    private func signalLabel(_ s: String) -> String { opts.signalMeta[s]?.label ?? s }
    private var valuePlaceholder: String {
        let label = meta?.valueLabel ?? "Value"
        let ex = meta?.example ?? ""
        return ex.isEmpty ? label : "\(label) (e.g. \(ex))"
    }

    // The layout editor's app picker draws from the running apps (same source as
    // the state trigger's app candidates).
    private var appCandidates: [String] { opts.signalCandidates["frontmostApp"] ?? [] }

    /// Display options for a placement: the connected displays, plus the
    /// placement's OWN display if it isn't connected now (so editing a captured
    /// "DELL" layout while undocked doesn't silently drop it).
    private func displayOptions(_ current: String) -> [String] {
        var out = opts.layoutDisplays
        let c = current.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty && !out.contains(c) { out.insert(c, at: 0) }
        return out.isEmpty ? (c.isEmpty ? [] : [c]) : out
    }

    private func addPlacement() {
        placements.append(Placement(screen: opts.layoutDisplays.last ?? "", pos: "full"))
    }

    /// Replace the rows with a snapshot of the current window arrangement. When the
    /// trigger names a specific display ("when <display> connects"), capture is
    /// scoped to THAT display -- so a 3-monitor setup grabs only the display the
    /// rule is about, not the others. Otherwise it captures every external display.
    private func capture() {
        let onlyDisplay = (signal == "displaysPresent")
            ? stateValue.trimmingCharacters(in: .whitespaces) : ""
        let snap = store.captureLayout(onlyDisplay: onlyDisplay)
        guard !snap.isEmpty else {
            formError = onlyDisplay.isEmpty
                ? "Nothing to capture -- capture takes only EXTERNAL-display windows "
                    + "(the built-in screen is skipped). Put a window on an external "
                    + "monitor, and make sure Hammerdeck has Accessibility."
                : "No windows on \"\(onlyDisplay)\" to capture -- move some there first "
                    + "(or it isn't connected right now)."
            return
        }
        placements = snap.map(placement(from:))
        formError = nil
    }

    /// Map a captured/stored placement dict to an editor row. A string `pos` is a
    /// grid id; a `{x,y,w,h}` table is exact ratios (captured), flagged as such.
    private func placement(from d: [String: Any]) -> Placement {
        var p = Placement()
        p.app = d["app"] as? String ?? ""
        p.screen = d["screen"] as? String ?? ""
        if let s = d["pos"] as? String {
            p.pos = s
        } else if let r = d["pos"] as? [String: Any] {
            func dbl(_ v: Any?) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? 0 }
            p.ratios = ["x": dbl(r["x"]), "y": dbl(r["y"]), "w": dbl(r["w"]), "h": dbl(r["h"])]
            p.pos = capturedPosId
        }
        return p
    }

    /// Warn when the typed value isn't currently present and we have a candidate
    /// list to compare against. Advisory -- naming a not-yet-present target is
    /// exactly how a "when it appears" rule is written, so the warning only
    /// stresses exact-match.
    private var stateValueWarning: String? {
        guard isStateTrigger else { return nil }
        let v = stateValue.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !candidates.isEmpty, !candidates.contains(v) else { return nil }
        return "\"\(v)\" isn't present right now -- the name must match exactly when it is, "
            + "or the rule won't fire."
    }

    private var canSubmit: Bool {
        if advanced {
            return !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isStateTrigger,
           stateValue.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedEffect?.kind == "notify",
           notifyTitle.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if selectedEffect?.kind == "layout" {
            return placements.contains {
                !$0.app.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.screen.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        if selectedEffect?.kind == "runShortcut" {
            return !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "openURL" {
            return !openURLValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return selectedEffect != nil
    }

    private func reloadOptions() {
        opts = store.ruleFormOptions()
        // If the selected state signal vanished, fall back to the first available.
        if isStateTrigger && !opts.signals.contains(signal) {
            triggerType = "state:" + (opts.signals.first ?? "frontmostApp")
        }
        if !opts.events.contains(eventName) { eventName = opts.events.first ?? "wake" }
        if !opts.effects.contains(where: { $0.id == effectId }) {
            effectId = opts.effects.first?.id ?? "notify"
        }
    }

    /// Reset every field to add-mode defaults.
    private func resetForm() {
        // Default to the app signal (not whichever sorts first), so a fresh rule
        // starts on the familiar "frontmost app" case.
        let defSig = opts.signals.contains("frontmostApp") ? "frontmostApp" : (opts.signals.first ?? "frontmostApp")
        triggerType = "state:" + defSig
        transition = "becomes"
        stateValue = ""
        eventName = opts.events.first ?? "wake"
        scheduleMode = "everyMin"
        everyMin = 25
        atTime = "09:00"
        effectId = opts.effects.first?.id ?? "notify"
        notifyTitle = "Hammerdeck"
        notifyText = ""
        placements = []
        shortcutName = ""
        openURLValue = ""
        formError = nil
        advanced = false
        jsonText = ""
        jsonSeed = ""
    }

    /// Reverse of buildSpec: seed the form fields from an existing rule's spec.
    private func loadForEdit(_ rule: RuleInfo) {
        formError = nil
        advanced = false   // selecting a rule starts in the guided form
        jsonText = ""
        jsonSeed = ""
        let on = rule.on
        let type = on["type"] as? String ?? "state"
        if type == "state" {
            let sig = on["signal"] as? String ?? (opts.signals.first ?? "frontmostApp")
            triggerType = "state:" + sig
            if let b = on["becomes"] as? String { transition = "becomes"; stateValue = b }
            else if let l = on["leaves"] as? String { transition = "leaves"; stateValue = l }
            else { transition = "becomes"; stateValue = "" }
        } else if type == "event" {
            triggerType = "event"
            eventName = on["event"] as? String ?? "wake"
        } else if type == "schedule" {
            triggerType = "schedule"
            if let e = on["everyMin"] as? Double { scheduleMode = "everyMin"; everyMin = Int(e) }
            else if let e = on["everyMin"] as? Int { scheduleMode = "everyMin"; everyMin = e }
            else if let a = on["at"] as? String { scheduleMode = "at"; atTime = a }
        } else {
            triggerType = "state:" + (opts.signals.first ?? "frontmostApp")
        }
        let effect = rule.effect
        let kind = effect["kind"] as? String
        if kind == "command" {
            let f = effect["feature"] as? String ?? ""
            if let a = effect["action"] as? String { effectId = "command:\(f).\(a)" }
            else { effectId = "command:\(f)." }
        } else if kind == "layout" {
            effectId = "layout"
            placements = ((effect["placements"] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }.map(placement(from:))
        } else if kind == "runShortcut" {
            effectId = "runShortcut"
            shortcutName = effect["name"] as? String ?? ""
        } else if kind == "openURL" {
            effectId = "openURL"
            openURLValue = effect["url"] as? String ?? ""
        } else if kind == "lockScreen" {
            effectId = "lockScreen"
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

    /// Save from the advanced JSON editor -- same engine path as the form, just
    /// the raw spec instead of the built one.
    private func submitJSON() {
        let text = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { formError = "the JSON is empty"; return }
        let reason = isEditing ? store.updateRule(editing!.id, text) : store.addRule(text)
        if let reason {
            formError = reason
        } else {
            editing = nil
            resetForm()
        }
    }

    /// The JSON to seed the advanced editor with. Editing an existing rule shows
    /// its SAVED spec (lossless -- preserves advanced fields the form can't hold);
    /// a new rule shows the in-progress form as JSON, or a starter template.
    private func currentSpecJSON() -> String {
        if let rule = editing {
            let s = store.ruleSpecJSON(rule.id)
            if !s.isEmpty { return s }
        }
        if let spec = buildSpec(),
           let data = try? JSONSerialization.data(
            withJSONObject: spec,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return Self.jsonTemplate
    }

    // A starter spec for a brand-new rule authored straight in JSON -- shows the
    // shape AND the titlePattern field (the thing the form can't express).
    private static let jsonTemplate = """
        {
          "on" : { "type" : "state", "signal" : "displaysPresent", "becomes" : "DELL U2720Q" },
          "effect" : {
            "kind" : "layout",
            "placements" : [
              { "app" : "Safari", "titlePattern" : "", "screen" : "DELL U2720Q", "pos" : "left" }
            ]
          }
        }
        """

    private func buildSpec() -> [String: Any]? {
        var on: [String: Any]
        if isStateTrigger {
            let v = stateValue.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, !signal.isEmpty else { return nil }
            on = ["type": "state", "signal": signal]
            on[transition] = v
        } else if triggerType == "event" {
            on = ["type": "event", "event": eventName]
        } else if triggerType == "schedule" {
            on = scheduleMode == "everyMin"
                ? ["type": "schedule", "everyMin": everyMin]
                : ["type": "schedule", "at": atTime]
        } else {
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
        } else if eff.kind == "layout" {
            let list: [[String: Any]] = placements.compactMap { p in
                let app = p.app.trimmingCharacters(in: .whitespaces)
                let screen = p.screen.trimmingCharacters(in: .whitespaces)
                guard !app.isEmpty, !screen.isEmpty else { return nil }
                var entry: [String: Any] = ["app": app, "screen": screen]
                if p.pos == capturedPosId, let r = p.ratios {
                    entry["pos"] = r            // exact captured ratios
                } else {
                    entry["pos"] = p.pos        // a named snap-grid id
                }
                return entry
            }
            guard !list.isEmpty else { return nil }
            effect = ["kind": "layout", "placements": list]
        } else if eff.kind == "runShortcut" {
            let n = shortcutName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            effect = ["kind": "runShortcut", "name": n]
        } else if eff.kind == "openURL" {
            let u = openURLValue.trimmingCharacters(in: .whitespaces)
            guard !u.isEmpty else { return nil }
            effect = ["kind": "openURL", "url": u]
        } else if eff.kind == "lockScreen" {
            effect = ["kind": "lockScreen"]
        } else {
            effect = ["kind": "command", "feature": eff.feature ?? ""]
            if let a = eff.action { effect["action"] = a }
        }
        return ["on": on, "effect": effect]
    }
}
