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
    // The detail form raises this while it holds unsaved JSON edits; switching the
    // selected rule then confirms before discarding them. (Form-FIELD edits are
    // cheap to retype and aren't guarded; hand-typed JSON isn't.)
    @State private var formDirty = false
    @State private var pendingSelection = ""   // a row awaiting the discard-confirm
    @State private var confirmSwitch = false

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
        .onAppear { store.refreshRules(); consumeDeepLink() }
        // A timeline rule-click sets store.selectedRuleId and switches here; open
        // that rule for editing (works whether we just appeared or were already up).
        .onChange(of: store.selectedRuleId) { _ in consumeDeepLink() }
        .confirmationDialog(Strings.t("rules.discardJSONTitle", default: "Discard your JSON edits?"),
                            isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button(Strings.t("rules.discardEdits", default: "Discard edits"), role: .destructive) {
                formDirty = false
                applySelection(pendingSelection)
            }
            Button(Strings.t("rules.keepEditing", default: "Keep editing"), role: .cancel) {}
        } message: {
            Text(Strings.t("rules.switchDiscardMsg", default: "Switching rules discards the changes you made in the JSON editor."))
        }
    }

    // List selection derived from `editing` (one source of truth): the rule's id,
    // or the "New rule" sentinel when adding. A switch away from a DIRTY JSON
    // editor is held for confirmation rather than silently discarded.
    private var selection: Binding<String?> {
        Binding(
            get: { editing?.id ?? newRowId },
            set: { row in
                let target = row ?? newRowId
                if target == (editing?.id ?? newRowId) { return }   // no-op (same row)
                if formDirty {
                    pendingSelection = target
                    confirmSwitch = true
                } else {
                    applySelection(target)
                }
            })
    }

    private func applySelection(_ row: String) {
        editing = (row == newRowId) ? nil : store.rules.first { $0.id == row }
    }

    /// Open the rule the timeline deep-linked to (store.selectedRuleId), then clear
    /// the request. refreshRules() must run first so store.rules is current.
    private func consumeDeepLink() {
        guard let rid = store.selectedRuleId else { return }
        if let r = store.rules.first(where: { $0.id == rid }) { editing = r }
        store.selectedRuleId = nil
    }

    private var ruleList: some View {
        List(selection: selection) {
            Section {
                Label(Strings.t("rules.newRule", default: "New rule"), systemImage: "plus.circle.fill")
                    .foregroundStyle(.tint).tag(newRowId)
            }
            Section(String(format: Strings.t("rules.sectionCount", default: "Rules (%d)"), store.rules.count)) {
                if store.rules.isEmpty {
                    Text(Strings.t("rules.noRulesYet", default: "No rules yet -- pick \"New rule\" to add one."))
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
                Text(Strings.t("rules.intro", default: "Rules fire an effect when something happens -- an app comes to the front, a display connects, on wake, or on a schedule. Pick a rule to edit it, or \"New rule\" to add one."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AddRuleForm(store: store, editing: $editing, formDirty: $formDirty)
        }
        .formStyle(.grouped)
        // Cap the form at a readable column width so it doesn't sprawl edge-to-edge
        // (labels flush-left, values flung to the far-right) in a wide window; the
        // outer frame centers that column and lets the rest be margin.
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, alignment: .center)
        .navigationTitle(Strings.t("rules.navTitle", default: "Rules"))
    }
}

// One row in the rule list: trigger -> effect, an on/off toggle, and delete.
// Selecting the row (anywhere else) opens it in the detail editor -- no separate
// pencil affordance, the selection IS the edit.
private struct RulePageRow: View {
    @ObservedObject var store: SettingsStore
    let rule: RuleInfo
    let onDelete: () -> Void

    // The last "Test" outcome, shown in a popover anchored to the Test button
    // (click anywhere to dismiss; nil = no popover). A struct so .popover(item:)
    // drives it.
    @State private var testResult: TestResult?
    // A pending Test on a DISRUPTIVE effect (lockScreen), held for confirmation --
    // "Test" reads like a preview, so firing one that locks the screen needs a
    // heads-up. Benign effects fire straight away (the tight verify loop).
    @State private var confirmDisruptiveTest = false

    private struct TestResult: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let message: String
    }

    // A named rule shows its name on top with trigger -> effect beneath; an
    // unnamed one keeps the original trigger / effect two-liner. An unavailable
    // rule shows what it WAS up top and gives the secondary line to the reason.
    private var primary: String {
        if !rule.name.isEmpty { return rule.name }
        if rule.unavailable { return "\(rule.triggerDesc) -> \(rule.effectDesc)" }
        return rule.triggerDesc
    }
    private var secondary: String {
        if rule.unavailable { return rule.unavailableReason }
        return rule.name.isEmpty ? rule.effectDesc : "\(rule.triggerDesc) -> \(rule.effectDesc)"
    }

    // The "fired 3m ago" / "not fired yet" status line. Hidden for unavailable
    // rules (their reason already holds the secondary line) and for a disabled
    // rule that never fired (a quiet off rule isn't a problem worth flagging).
    private var fireStatus: (text: String, color: Color)? {
        if rule.unavailable { return nil }
        if let at = rule.lastFired {
            let verb = rule.lastFiredTest ? Strings.t("rules.verbTested", default: "tested")
                                          : Strings.t("rules.verbFired", default: "fired")
            let ago = Self.relativeAgo(at)
            return rule.lastFiredOk
                ? (String(format: Strings.t("rules.fireStatus", default: "%@ %@"), verb, ago), .secondary)
                : (String(format: Strings.t("rules.fireStatusFailed", default: "%@ %@ -- failed"), verb, ago), .orange)
        }
        return rule.enabled ? (Strings.t("rules.notFiredYet", default: "not fired yet"), .secondary) : nil
    }

    private static func relativeAgo(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 45 { return Strings.t("rules.justNow", default: "just now") }
        if s < 3600 { return String(format: Strings.t("rules.minutesAgo", default: "%dm ago"), Int((s / 60).rounded())) }
        if s < 86_400 { return String(format: Strings.t("rules.hoursAgo", default: "%dh ago"), Int((s / 3600).rounded())) }
        return String(format: Strings.t("rules.daysAgo", default: "%dd ago"), Int((s / 86_400).rounded()))
    }

    var body: some View {
        HStack(spacing: 8) {
            if rule.unavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).help(rule.unavailableReason)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(.callout).lineLimit(1)
                Text(secondary).font(.caption)
                    .foregroundStyle(rule.unavailable ? .orange : .secondary).lineLimit(1)
                if let status = fireStatus {
                    Text(status.text).font(.caption2)
                        .foregroundStyle(status.color).lineLimit(1)
                }
            }
            Spacer()
            // Test + enable are meaningless for an unavailable rule (its effect
            // can't run, it isn't bound) -- it offers only Delete, plus
            // select-to-edit (which opens its raw JSON so the user can fix it).
            if !rule.unavailable {
                Button(action: runTest) {
                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Strings.t("rules.testHelp", default: "Test this rule now -- fire its effect without waiting for the trigger"))
                .popover(item: $testResult) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: r.icon).foregroundStyle(r.color)
                        Text(r.message).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).frame(maxWidth: 300)
                }
                .confirmationDialog(String(format: Strings.t("rules.testLockTitle", default: "Test \"%@\"? This will lock your screen now."), primary),
                                    isPresented: $confirmDisruptiveTest, titleVisibility: .visible) {
                    Button(Strings.t("rules.lockScreen", default: "Lock screen"), role: .destructive) { fireNow() }
                    Button(Strings.t("rules.cancel", default: "Cancel"), role: .cancel) {}
                }
                Toggle("", isOn: Binding(get: { rule.enabled },
                                         set: { store.setRuleEnabled(rule.id, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(rule.enabled ? Strings.t("rules.enabled", default: "Enabled") : Strings.t("rules.disabled", default: "Disabled"))
            }
            Button(action: onDelete) {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).help(Strings.t("rules.deleteHelp", default: "Delete this rule"))
        }
        .padding(.vertical, 2)
        .opacity(rule.unavailable ? 0.6 : (rule.enabled ? 1 : 0.55))
    }

    // Disruptive built-in effects whose Test should confirm first (locking the
    // screen on a "preview" click is a nasty surprise). Other effects -- including
    // user-authored runShortcut/command, whose whole point is to run -- fire
    // immediately. Widen this if a sleep/shutdown-style effect is ever added.
    private static let disruptiveTestKinds: Set<String> = ["lockScreen"]

    private func runTest() {
        if let kind = rule.effect["kind"] as? String,
           Self.disruptiveTestKinds.contains(kind) {
            confirmDisruptiveTest = true   // hand the real fire to the dialog's button
            return
        }
        fireNow()
    }

    private func fireNow() {
        let (ok, message) = store.fireRule(rule.id)
        // Three outcomes: clean fire (green check), partial fire (orange triangle
        // + the note: "moved 1/2 -- no window for: Mail"), failure (red x + reason).
        if ok && message.isEmpty {
            testResult = TestResult(icon: "checkmark.circle.fill", color: .green, message: Strings.t("rules.firedMessage", default: "Fired"))
        } else if ok {
            testResult = TestResult(icon: "exclamationmark.triangle.fill", color: .orange, message: message)
        } else {
            testResult = TestResult(icon: "xmark.circle.fill", color: .red,
                                    message: message.isEmpty ? Strings.t("rules.effectFailed", default: "Effect failed") : message)
        }
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

/// One step of a `chain` effect in the form editor -- one of the simple
/// context-free atoms. A chain step that's a layout or command is authored in
/// JSON, not here (loadForEdit drops such a chain into the JSON editor).
private struct ChainStep: Identifiable {
    let id = UUID()
    var kind: String = "notify"
    var notifyTitle: String = AppInfo.displayName
    var notifyText: String = ""
    var notifyChannel: String = "system"
    var shortcutName: String = ""
    var url: String = ""
}
private let chainStepKinds: [(id: String, label: String)] = [
    ("notify", Strings.t("rules.chainKindNotify", default: "Notify")),
    ("runShortcut", Strings.t("rules.chainKindRunShortcut", default: "Run a Shortcut")),
    ("openURL", Strings.t("rules.chainKindOpenURL", default: "Open a URL")),
    ("lockScreen", Strings.t("rules.chainKindLockScreen", default: "Lock the screen")),
]
private let chainStepSimpleKinds: Set<String> = ["notify", "runShortcut", "openURL", "lockScreen"]

private struct AddRuleForm: View {
    @ObservedObject var store: SettingsStore
    @Binding var editing: RuleInfo?
    // Raised while the JSON editor holds unsaved edits, so the parent can confirm
    // before a rule-switch discards them. Kept in sync by the onChange hooks below.
    @Binding var formDirty: Bool

    @State private var opts = RuleFormOptions([:])
    // An optional human label for the rule -- the list shows it instead of the
    // terse trigger text ("Dock at desk" reads better than "displaysPresent ...").
    @State private var name = ""
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
    @State private var notifyTitle = AppInfo.displayName
    @State private var notifyText = ""
    @State private var notifyChannel = "system"       // system (Notification Center) | app (banner)
    @State private var placements: [Placement] = []   // the layout effect's rows
    @State private var chainSteps: [ChainStep] = []   // the chain effect's ordered steps
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
        Section(isEditing ? Strings.t("rules.editRule", default: "Edit rule") : Strings.t("rules.addRuleSection", default: "Add a rule")) {
            // The form is THE editor; JSON is a discreet escape hatch shown only
            // where it pays off -- a `layout` effect, the one thing the form can't
            // fully express (a placement's titlePattern). For every other effect
            // the form is complete, so the link would be noise. It stays visible in
            // JSON mode regardless, so "Use the form" is always a way back.
            // toggleMode GUARDS the JSON->Form switch when the editor is dirty.
            if advanced || selectedEffect?.kind == "layout" {
                HStack {
                    Spacer()
                    Button(action: toggleMode) {
                        Label(advanced ? Strings.t("rules.useForm", default: "Use the form") : Strings.t("rules.editAsJSON", default: "Edit as JSON"),
                              systemImage: advanced ? "list.bullet" : "curlybraces")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .help(advanced ? Strings.t("rules.useFormHelp", default: "Switch back to the guided form")
                                   : Strings.t("rules.editJSONHelp", default: "Edit this rule's raw JSON spec -- reaches a window's titlePattern"))
                }
            }

            if advanced {
                jsonEditor
            } else {
            TextField(Strings.t("rules.namePlaceholder", default: "Name (optional)"), text: $name)
            Picker(Strings.t("rules.when", default: "When"), selection: $triggerType) {
                // Each state signal is its own top-level choice (Frontmost app,
                // Connected display, ...) -- no nested "Signal" picker.
                ForEach(opts.signals, id: \.self) { sig in
                    Text(signalLabel(sig)).tag("state:" + sig)
                }
                Text(Strings.t("rules.systemEvent", default: "System event")).tag("event")
                Text(Strings.t("rules.schedule", default: "Schedule")).tag("schedule")
            }

            if isStateTrigger {
                Picker(Strings.t("rules.transition", default: "Transition"), selection: $transition) {
                    Text(meta?.enterVerb ?? Strings.t("rules.becomes", default: "becomes")).tag("becomes")
                    Text(meta?.leaveVerb ?? Strings.t("rules.leaves", default: "leaves")).tag("leaves")
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
                        .help(Strings.t("rules.pickSuggested", default: "Pick a suggested value"))
                    }
                }
                if let warning = stateValueWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if triggerType == "event" {
                Picker(Strings.t("rules.event", default: "Event"), selection: $eventName) {
                    ForEach(opts.events, id: \.self) { Text($0).tag($0) }
                }
            } else if triggerType == "schedule" {
                Picker(Strings.t("rules.mode", default: "Mode"), selection: $scheduleMode) {
                    Text(Strings.t("rules.everyNMinutes", default: "Every N minutes")).tag("everyMin")
                    Text(Strings.t("rules.dailyAt", default: "Daily at")).tag("at")
                }
                if scheduleMode == "everyMin" {
                    Stepper(String(format: Strings.t("rules.everyMinStepper", default: "Every %d min"), everyMin), value: $everyMin, in: 1...1440)
                } else {
                    TextField(Strings.t("rules.hhmm", default: "HH:MM"), text: $atTime)
                    if !Self.isValidHHMM(atTime) {
                        Text(Strings.t("rules.hhmmHint", default: "Enter a 24-hour time like 09:00 or 23:30."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Picker(Strings.t("rules.do", default: "Do"), selection: $effectId) {
                ForEach(opts.effects) { e in Text(e.label).tag(e.id) }
            }
            if selectedEffect?.kind == "notify" {
                TextField(Strings.t("rules.notifyTitleField", default: "Notification title"), text: $notifyTitle)
                TextField(Strings.t("rules.notifyTextField", default: "Notification text (optional)"), text: $notifyText)
                Picker(Strings.t("rules.showAs", default: "Show as"), selection: $notifyChannel) {
                    Text(Strings.t("rules.systemNotification", default: "System notification")).tag("system")
                    Text(Strings.t("rules.inAppBanner", default: "In-app banner")).tag("app")
                }
                if notifyChannel == "system" {
                    Text(Strings.t("rules.notifyChannelHint", default: "Appears in Notification Center -- persists in history, shows on the lock screen, and respects Focus. Needs the packaged app; a dev run falls back to the in-app banner."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if selectedEffect?.kind == "layout" {
                layoutEditor
            } else if selectedEffect?.kind == "runShortcut" {
                TextField(Strings.t("rules.shortcutNameField", default: "Shortcut name (exactly as in the Shortcuts app)"), text: $shortcutName)
                Text(Strings.t("rules.runShortcutHint", default: "Runs a macOS Shortcut -- the escape hatch to Focus/DND, volume, HomeKit, and anything Shortcuts can do."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if selectedEffect?.kind == "openURL" {
                TextField(Strings.t("rules.openURLField", default: "URL (https://… , or an app scheme like raycast://…)"), text: $openURLValue)
            } else if selectedEffect?.kind == "chain" {
                chainEditor
            }
            }   // end of the Form-mode (!advanced) fields

            if let formError {
                Label(formError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isEditing {
                    Button(Strings.t("rules.cancel", default: "Cancel")) { editing = nil }   // onChange resets the form
                }
                Button(isEditing ? Strings.t("rules.saveChanges", default: "Save changes") : Strings.t("rules.addRule", default: "Add rule")) {
                    advanced ? submitJSON() : submit()
                }
                .disabled(!canSubmit)
            }
        }
        .onAppear(perform: reloadOptions)
        // Hosted on the Section (always present), not the conditional link above,
        // so the dialog is never torn down mid-presentation when the link hides.
        .confirmationDialog(Strings.t("rules.discardJSONTitle", default: "Discard your JSON edits?"),
                            isPresented: $confirmLeaveJSON, titleVisibility: .visible) {
            Button(Strings.t("rules.discardEdits", default: "Discard edits"), role: .destructive) { advanced = false }
            Button(Strings.t("rules.keepEditingJSON", default: "Keep editing JSON"), role: .cancel) {}
        } message: {
            Text(Strings.t("rules.switchToFormMsg", default: "Switching to the form discards the changes you made in the JSON editor."))
        }
        // Entering JSON mode seeds the editor with the rule's current spec and
        // records that seed (so the toggle binding can tell if it was edited).
        .onChange(of: advanced) { on in
            if on { jsonText = currentSpecJSON(); jsonSeed = jsonText }
            formDirty = on && jsonText != jsonSeed
        }
        // Keep the parent's dirty flag live as the user types in the JSON editor.
        .onChange(of: jsonText) { _ in formDirty = advanced && jsonText != jsonSeed }
        // Drive the form from the selection: a rule -> pre-fill (edit), nil -> reset (add).
        .onChange(of: editing?.id) { _ in
            if let rule = editing { loadForEdit(rule) } else { resetForm() }
        }
        // Seed a first row when the user switches the effect to "layout"/"chain".
        .onChange(of: effectId) { _ in
            if selectedEffect?.kind == "layout" && placements.isEmpty { addPlacement() }
            if selectedEffect?.kind == "chain" && chainSteps.isEmpty { chainSteps.append(ChainStep()) }
        }
    }

    // The advanced raw-JSON editor for one rule's full spec. Saving validates
    // through the same engine path as the form (addJSON / updateJSON), so a bad
    // spec comes back as an inline error, never a crash.
    @ViewBuilder private var jsonEditor: some View {
        Text(Strings.t("rules.jsonEditorHint", default: "Edit this rule's full spec as JSON -- this reaches what the form can't. Each layout window shows a \"titlePattern\": fill it with part of a window's title (case-insensitive) to target one of several same-app windows (leave \"\" to match any). Saving validates the spec."))
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
            Text(Strings.t("rules.noWindowsYet", default: "No windows yet -- add one, or capture your current arrangement."))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(placements.enumerated()), id: \.element.id) { i, p in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField(Strings.t("rules.appField", default: "App (e.g. Safari)"), text: $placements[i].app)
                    if !appCandidates.isEmpty {
                        Menu {
                            ForEach(appCandidates, id: \.self) { a in
                                Button(a) { placements[i].app = a }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).frame(width: 30)
                        .help(Strings.t("rules.pickRunningApps", default: "Pick from running apps"))
                    }
                    Button(role: .destructive) {
                        placements.removeAll { $0.id == p.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help(Strings.t("rules.removeWindow", default: "Remove this window"))
                }
                // Stacked (not side-by-side) so a long display name never forces a
                // wider pane -- the row reflows to whatever width it's given.
                Picker(Strings.t("rules.display", default: "Display"), selection: $placements[i].screen) {
                    ForEach(displayOptions(p.screen), id: \.self) { Text($0).tag($0) }
                }
                Picker(Strings.t("rules.position", default: "Position"), selection: $placements[i].pos) {
                    if p.ratios != nil { Text(Strings.t("rules.captured", default: "Captured")).tag(capturedPosId) }
                    ForEach(opts.layoutPositions) { Text($0.label).tag($0.id) }
                }
                // canSubmit only needs ONE complete row, and buildSpec drops the
                // incomplete ones -- so flag a half-filled row instead of silently
                // dropping it on save.
                if p.app.trimmingCharacters(in: .whitespaces).isEmpty
                    || p.screen.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(Strings.t("rules.windowIncomplete", default: "Incomplete -- set an app + display, or this window is skipped on save."))
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        }
        HStack {
            Button { addPlacement() } label: { Label(Strings.t("rules.addWindow", default: "Add window"), systemImage: "plus") }
            Spacer()
            Button { capture() } label: {
                Label(Strings.t("rules.captureLayout", default: "Capture current layout"), systemImage: "camera.viewfinder")
            }
            .help(Strings.t("rules.captureLayoutHelp", default: "Snapshot where your windows are arranged right now"))
        }
    }

    // The repeatable, ordered chain-step editor (shown when the effect is "chain").
    // Each step is one simple context-free atom; a chain with a layout/command step
    // is authored in JSON (loadForEdit routes it there).
    @ViewBuilder private var chainEditor: some View {
        if chainSteps.isEmpty {
            Text(Strings.t("rules.noStepsYet", default: "No steps yet -- add one. Steps run top to bottom."))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(chainSteps.enumerated()), id: \.element.id) { i, s in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Picker("", selection: $chainSteps[i].kind) {
                        ForEach(chainStepKinds, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    Spacer()
                    Button(role: .destructive) {
                        chainSteps.removeAll { $0.id == s.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help(Strings.t("rules.removeStep", default: "Remove this step"))
                }
                switch chainSteps[i].kind {
                case "notify":
                    TextField(Strings.t("rules.notifyTitleField", default: "Notification title"), text: $chainSteps[i].notifyTitle)
                    TextField(Strings.t("rules.notifyTextField", default: "Notification text (optional)"), text: $chainSteps[i].notifyText)
                    Picker(Strings.t("rules.showAs", default: "Show as"), selection: $chainSteps[i].notifyChannel) {
                        Text(Strings.t("rules.chainSystem", default: "System")).tag("system")
                        Text(Strings.t("rules.chainInApp", default: "In-app")).tag("app")
                    }
                case "runShortcut":
                    TextField(Strings.t("rules.shortcutNameField", default: "Shortcut name (exactly as in the Shortcuts app)"),
                              text: $chainSteps[i].shortcutName)
                case "openURL":
                    TextField(Strings.t("rules.openURLFieldShort", default: "URL (https://… or an app scheme)"), text: $chainSteps[i].url)
                default:
                    EmptyView()   // lockScreen has no fields
                }
                if !chainStepComplete(chainSteps[i]) {
                    Text(Strings.t("rules.stepIncomplete", default: "Incomplete -- fill the field, or this step is skipped on save."))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        }
        Button { chainSteps.append(ChainStep()) } label: { Label(Strings.t("rules.addStep", default: "Add step"), systemImage: "plus") }
    }

    private func chainStepComplete(_ s: ChainStep) -> Bool {
        switch s.kind {
        case "notify":      return !s.notifyTitle.trimmingCharacters(in: .whitespaces).isEmpty
        case "runShortcut": return !s.shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        case "openURL":     return !s.url.trimmingCharacters(in: .whitespaces).isEmpty
        case "lockScreen":  return true
        default:            return false
        }
    }

    /// Map a stored chain-step dict to an editor row, or nil if it's a kind the
    /// form doesn't edit (layout/command -- such a chain opens in JSON instead).
    private func chainStep(from d: [String: Any]) -> ChainStep? {
        guard let k = d["kind"] as? String, chainStepSimpleKinds.contains(k) else { return nil }
        var s = ChainStep()
        s.kind = k
        s.notifyTitle = d["title"] as? String ?? AppInfo.displayName
        s.notifyText = d["text"] as? String ?? ""
        s.notifyChannel = d["channel"] as? String ?? "app"
        s.shortcutName = d["name"] as? String ?? ""
        s.url = d["url"] as? String ?? ""
        return s
    }

    // Guards the Form/JSON toggle: leaving the JSON editor while it's dirty
    // (jsonText differs from its seed) asks first, so a mis-tap never silently
    // discards typed JSON. Entering JSON (form -> JSON) always switches at once.
    private func toggleMode() {
        if advanced && jsonText != jsonSeed {
            confirmLeaveJSON = true     // dirty JSON -> confirm before leaving
        } else {
            advanced.toggle()
        }
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
        let label = meta?.valueLabel ?? Strings.t("rules.value", default: "Value")
        let ex = meta?.example ?? ""
        return ex.isEmpty ? label : String(format: Strings.t("rules.valueExample", default: "%@ (e.g. %@)"), label, ex)
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
                ? String(format: Strings.t("rules.captureEmptyError", default: "Nothing to capture -- capture takes only EXTERNAL-display windows (the built-in screen is skipped). Put a window on an external monitor, and make sure %@ has Accessibility."), AppInfo.displayName)
                : String(format: Strings.t("rules.captureNoWindowsError", default: "No windows on \"%@\" to capture -- move some there first (or it isn't connected right now)."), onlyDisplay)
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
        return String(format: Strings.t("rules.notPresentWarning", default: "\"%@\" isn't present right now -- the name must match exactly when it is, or the rule won't fire."), v)
    }

    // A 24-hour HH:MM (1-2 digit hour 0-23, 2-digit minute 0-59) -- mirrors the
    // engine's range check so the form grays "Add" instead of failing on save.
    private static func isValidHHMM(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return false }
        return true
    }

    private var canSubmit: Bool {
        if advanced {
            return !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if triggerType == "schedule", scheduleMode == "at", !Self.isValidHHMM(atTime) {
            return false
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
        if selectedEffect?.kind == "chain" {
            return chainSteps.contains { chainStepComplete($0) }
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
        name = ""
        triggerType = "state:" + defSig
        transition = "becomes"
        stateValue = ""
        eventName = opts.events.first ?? "wake"
        scheduleMode = "everyMin"
        everyMin = 25
        atTime = "09:00"
        effectId = opts.effects.first?.id ?? "notify"
        notifyTitle = AppInfo.displayName
        notifyText = ""
        notifyChannel = "system"
        placements = []
        chainSteps = []
        shortcutName = ""
        openURLValue = ""
        formError = nil
        advanced = false
        jsonText = ""
        jsonSeed = ""
        formDirty = false
    }

    /// Reverse of buildSpec: seed the form fields from an existing rule's spec.
    private func loadForEdit(_ rule: RuleInfo) {
        formError = nil
        advanced = false   // selecting a rule starts in the guided form
        jsonText = ""
        jsonSeed = ""
        name = rule.name
        // A rule whose trigger or effect the guided form can't fully model (a
        // hotkey/chord trigger this form doesn't author, or a command targeting a
        // feature that's no longer offered) opens in the lossless JSON editor below
        // -- NOT silently rewritten into a state trigger that Save would then clobber.
        var representable = true
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
            representable = false   // hotkey/chord (or any non-form trigger)
        }
        // Clear all effect-specific fields first, so values from a previously-edited
        // rule (e.g. layout placements) can't bleed into one of a different kind --
        // the onChange(of: effectId) seeder only fills an EMPTY placement list.
        placements = []; chainSteps = []; shortcutName = ""; openURLValue = ""
        notifyTitle = AppInfo.displayName; notifyText = ""
        let effect = rule.effect
        let kind = effect["kind"] as? String
        if kind == "command" {
            let f = effect["feature"] as? String ?? ""
            if let a = effect["action"] as? String { effectId = "command:\(f).\(a)" }
            else { effectId = "command:\(f)." }
            // The "Do" dropdown only offers automatable commands of ENABLED
            // features; a command whose target vanished can't be shown in the form.
            if !opts.effects.contains(where: { $0.id == effectId }) { representable = false }
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
        } else if kind == "chain" {
            effectId = "chain"
            let steps = (effect["effects"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            chainSteps = steps.compactMap(chainStep(from:))
            // a chain with a step the form can't edit (layout/command) -> JSON
            if steps.count != chainSteps.count { representable = false }
        } else {
            effectId = "notify"
            notifyTitle = effect["title"] as? String ?? AppInfo.displayName
            notifyText = effect["text"] as? String ?? ""
            // Absent channel = the in-app banner (back-compat: rules authored before
            // the system/app choice existed kept the old Toast behavior).
            notifyChannel = effect["channel"] as? String ?? "app"
        }
        // Not fully representable (a non-form trigger, a vanished command target,
        // or a parked/unavailable rule whose signal is gone) -> open the raw spec
        // in JSON, seeded directly (not via onChange(of: advanced), which wouldn't
        // fire if we were already in JSON mode). The form's "Use the form" link is
        // still available if the user WANTS to convert it -- but it's now an
        // explicit choice, not a silent rewrite-on-Save. Editing + saving the JSON
        // keeps the id and name, and fixing a parked rule un-parks it.
        if !representable || rule.unavailable {
            advanced = true
            jsonText = currentSpecJSON()
            jsonSeed = jsonText
        }
    }

    private func submit() {
        guard let spec = buildSpec(),
              let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else {
            formError = Strings.t("rules.couldNotBuild", default: "could not build the rule")
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
        guard !text.isEmpty else { formError = Strings.t("rules.jsonEmpty", default: "the JSON is empty"); return }
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
            effect = ["kind": "notify", "title": t, "channel": notifyChannel]
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
        } else if eff.kind == "chain" {
            // Drop incomplete steps (mirrors layout); keep order.
            let steps: [[String: Any]] = chainSteps.compactMap { s in
                switch s.kind {
                case "notify":
                    let t = s.notifyTitle.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return nil }
                    var e: [String: Any] = ["kind": "notify", "title": t, "channel": s.notifyChannel]
                    let body = s.notifyText.trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { e["text"] = body }
                    return e
                case "runShortcut":
                    let n = s.shortcutName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return nil }
                    return ["kind": "runShortcut", "name": n]
                case "openURL":
                    let u = s.url.trimmingCharacters(in: .whitespaces)
                    guard !u.isEmpty else { return nil }
                    return ["kind": "openURL", "url": u]
                case "lockScreen":
                    return ["kind": "lockScreen"]
                default:
                    return nil
                }
            }
            guard !steps.isEmpty else { return nil }
            effect = ["kind": "chain", "effects": steps]
        } else if eff.kind == "lockScreen" {
            effect = ["kind": "lockScreen"]
        } else {
            effect = ["kind": "command", "feature": eff.feature ?? ""]
            if let a = eff.action { effect["action"] = a }
        }
        var spec: [String: Any] = ["on": on, "effect": effect]
        let label = name.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { spec["name"] = label }
        return spec
    }
}
