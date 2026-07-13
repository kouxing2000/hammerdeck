import SwiftUI
import AppKit                    // NSOpenPanel (the wallpaper-image file picker)
import UniformTypeIdentifiers    // UTType.image

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

    // The rule's plain-English description -- the engine sentence ("When Claude loses
    // focus, minimize it."), or a trigger -> effect fallback when the grammar can't
    // phrase it. This is the SAME sentence the editor's Name placeholder previews.
    private var ruleDescription: String {
        rule.sentence.isEmpty ? "\(rule.triggerDesc) -> \(rule.effectDesc)" : rule.sentence
    }
    // A named rule shows its name on top with the sentence beneath; an UNNAMED one
    // lists AS the sentence (one line, so the placeholder is a true preview of the
    // row -- no redundant subtitle). An unavailable rule shows what it WAS up top and
    // gives the secondary line to the reason.
    private var primary: String {
        rule.name.isEmpty ? ruleDescription : rule.name
    }
    private var secondary: String {
        if rule.unavailable { return rule.unavailableReason }
        return rule.name.isEmpty ? "" : ruleDescription
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
                ? (String(format: Strings.t("rules.fireStatus", default: "%1$@ %2$@"), verb, ago), .secondary)
                : (String(format: Strings.t("rules.fireStatusFailed", default: "%1$@ %2$@ -- failed"), verb, ago), .orange)
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
                if !secondary.isEmpty {
                    Text(secondary).font(.caption)
                        .foregroundStyle(rule.unavailable ? .orange : .secondary).lineLimit(1)
                }
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
                // Test fires the effect WITHOUT its trigger -- meaningless for a "from
                // the trigger" effect, which needs the live trigger to supply its value
                // (firing it in isolation has no context). Such a rule is verified by
                // staging its trigger (connect the display, switch apps), so hide Test.
                if !rule.contextBound {
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
                    .confirmationDialog(disruptiveTestTitle,
                                        isPresented: $confirmDisruptiveTest, titleVisibility: .visible) {
                        Button(disruptiveTestButton, role: .destructive) { fireNow() }
                        Button(Strings.t("rules.cancel", default: "Cancel"), role: .cancel) {}
                    }
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

    // Disruptive built-in effects whose Test should confirm first -- locking the
    // screen on a "preview" click is a nasty surprise, and emptyTrash/eject are
    // IRREVERSIBLE, so a misleading or absent prompt is a real safety hazard. Other
    // effects -- including user-authored runShortcut/command, whose whole point is
    // to run -- fire immediately. Widen this if a sleep/shutdown-style effect lands.
    private static let disruptiveTestKinds: Set<String> = ["lockScreen", "startScreensaver", "emptyTrash", "eject"]

    // The disruptive kind a Test must confirm before firing: the effect's own kind,
    // or -- for a chain -- the first step that's destructive (so a chain that empties
    // the Trash still prompts, and prompts about the RIGHT thing). nil = fire freely.
    private var disruptiveTestKind: String? {
        guard let kind = rule.effect["kind"] as? String else { return nil }
        if Self.disruptiveTestKinds.contains(kind) { return kind }
        if kind == "chain" {
            let steps = (rule.effect["effects"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            let disruptive = steps.compactMap { $0["kind"] as? String }
                .filter { Self.disruptiveTestKinds.contains($0) }
            // Warn about the IRREVERSIBLE step (empty Trash / eject) ahead of a
            // reversible one (lock / screensaver) when a chain mixes them.
            return disruptive.first { $0 == "emptyTrash" || $0 == "eject" } ?? disruptive.first
        }
        return nil
    }

    // Per-kind confirm copy -- the dialog must describe the ACTUAL destructive act,
    // never a stale "lock screen" while it deletes the Trash (the safety gate is
    // worthless if it misinforms).
    private var disruptiveTestTitle: String {
        switch disruptiveTestKind {
        case "emptyTrash":
            return String(format: Strings.t("rules.testEmptyTrashTitle", default: "Test \"%@\"? This permanently empties your Trash now."), primary)
        case "eject":
            return String(format: Strings.t("rules.testEjectTitle", default: "Test \"%@\"? This ejects your external disks now."), primary)
        case "startScreensaver":
            return String(format: Strings.t("rules.testScreensaverTitle", default: "Test \"%@\"? This starts the screensaver now."), primary)
        default:
            return String(format: Strings.t("rules.testLockTitle", default: "Test \"%@\"? This will lock your screen now."), primary)
        }
    }
    private var disruptiveTestButton: String {
        switch disruptiveTestKind {
        case "emptyTrash":       return Strings.t("rules.testEmptyTrashConfirm", default: "Empty Trash")
        case "eject":            return Strings.t("rules.testEjectConfirm", default: "Eject disks")
        case "startScreensaver": return Strings.t("rules.testScreensaverConfirm", default: "Start screensaver")
        default:                 return Strings.t("rules.lockScreen", default: "Lock screen")
        }
    }

    private func runTest() {
        if disruptiveTestKind != nil {
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
// Internal (not private): RuleFormModel (a separate file) + its tests build these.
struct Placement: Identifiable {
    let id = UUID()
    var app: String = ""
    var screen: String = ""
    var pos: String = "full"
    var ratios: [String: Double]? = nil
}
let capturedPosId = "__captured__"
// The app-target effect kinds (minimize/hide/quit a named app). File-level so
// both AddRuleForm and RuleFormModel.buildSpec share one source.
let appTargetKinds: Set<String> = ["minimizeApp", "hideApp", "quitApp"]

/// One tappable token in the rule sentence: a rounded accent pill whose label is
/// the current value, opening `popover` to change it. Mirrors the timeline marker
/// pill (AutomationTimelineView). `muted` (an empty value) greys it to read as a
/// placeholder; `anaphor` ("it") tints it to read as a pronoun referring back to
/// the trigger value. A pill always has a popover -- plain connective words use a
/// bare Text instead (AddRuleForm.sentenceWord).
private struct TokenPill<Popover: View>: View {
    let text: String
    var muted: Bool = false
    var anaphor: Bool = false
    var help: String = ""
    @ViewBuilder let popover: () -> Popover
    @State private var showing = false

    private var tint: Color { anaphor ? .purple : .accentColor }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 3) {
                Text(text)
                    .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)   // cap: a long name truncates, never blows the row
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(muted ? 0.06 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(tint.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            popover().padding(14)
        }
    }
}

/// One step of a `chain` effect in the form editor -- one of the simple
/// context-free atoms. A chain step that's a layout or command is authored in
/// JSON, not here (loadForEdit drops such a chain into the JSON editor).
struct ChainStep: Identifiable {
    let id = UUID()
    var kind: String = "notify"
    var notifyTitle: String = AppInfo.displayName
    var notifyText: String = ""
    var notifyChannel: String = "system"
    var shortcutName: String = ""
    var url: String = ""
    var speakText: String = ""
}
private let chainStepKinds: [(id: String, label: String)] = [
    ("notify", Strings.t("rules.chainKindNotify", default: "Notify")),
    ("speak", Strings.t("rules.chainKindSpeak", default: "Speak text aloud")),
    ("runShortcut", Strings.t("rules.chainKindRunShortcut", default: "Run a Shortcut")),
    ("openURL", Strings.t("rules.chainKindOpenURL", default: "Open a URL")),
    ("lockScreen", Strings.t("rules.chainKindLockScreen", default: "Lock the screen")),
    ("startScreensaver", Strings.t("rules.chainKindScreensaver", default: "Start the screensaver")),
    ("emptyTrash", Strings.t("rules.chainKindEmptyTrash", default: "Empty the Trash")),
    ("eject", Strings.t("rules.chainKindEject", default: "Eject external disks")),
]
private let chainStepSimpleKinds: Set<String> = ["notify", "speak", "runShortcut", "openURL", "lockScreen", "startScreensaver", "emptyTrash", "eject"]

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
    @State private var speakText = ""                 // speak
    @State private var wallpaperImage = ""             // setWallpaperImage: image file path
    @State private var solidColor = "#FFFFFF"          // solidWallpaper: preset hex
    // Empty until the effect is chosen, then seeded-if-empty (uniform with
    // minimizeAppName) -- so a recipe's explicit display survives the effect seeder.
    @State private var solidDisplay = ""               // solidWallpaper: name | all | external | primary | sentinel
    @State private var minimizeAppName = ""            // minimizeApp: app name | @trigger:app
    @State private var moveApp = ""                    // moveAppToDisplay: app name | @trigger:app
    @State private var moveDisplay = ""                // moveAppToDisplay: display name | @trigger:display
    // The canonical match key paired with the *Name display string above: a bundle
    // id (set when the user picks from the installed-apps list), so a rule matches
    // by bundle id (stable across locale/rename), not the localized name. Empty for
    // the "@trigger:app" sentinel and for a manually-typed name (then the engine
    // falls back to name-matching). Persisted as the effect's `appBundleId`.
    @State private var minimizeAppBundleId = ""        // minimizeApp/hideApp/quitApp
    @State private var moveAppBundleId = ""            // moveAppToDisplay
    // launchApp (Open an app): unlike the act-on-running-app effects above, launch
    // REQUIRES a bundle id (the only launchable identifier), so this drives canSubmit
    // -- a free-typed name alone can't open an app. No "@trigger:app" form (you can't
    // meaningfully launch the app a trigger reacts to), so it needs its own state.
    @State private var launchAppName = ""              // launchApp: display name
    @State private var launchAppBundleId = ""          // launchApp: the launch key (required)
    // The three system state-changers demoted from thin features to rules atoms.
    // Each is a single enum the sub-picker sets; always valid, so no canSubmit gate.
    @State private var appearanceMode = "dark"         // setAppearance: dark | light | toggle
    @State private var volumeOp = "up"                 // volume: up | down | mute
    @State private var mediaKeyName = "playpause"      // mediaKey: playpause | next | previous
    // The frontmostApp TRIGGER value reuses the installed-apps chooser (so a rule can
    // watch for an app that isn't running yet). stateValue holds the display NAME (the
    // sentence reads it); stateValueBundleId is the bundle id stored as `on.bundleId`
    // -- the signal matches on THAT (stable across locale/rename), the name only as a
    // free-text fallback. Empty for a typed name or a non-app signal.
    @State private var showFrontmostPicker = false
    @State private var stateValueBundleId = ""
    // The "New rule" landing: a recipe gallery (kills the blank canvas), shown only
    // in add mode. Picking a recipe pre-fills the form below; "Build your own" clears it.
    @State private var showGallery = true
    @State private var formError: String?
    // Advanced "Edit as JSON" mode: one rule, one JSON spec.
    @State private var advanced = false
    @State private var jsonText = ""
    @State private var jsonSeed = ""            // what jsonText was seeded with (dirty check)
    @State private var confirmLeaveJSON = false
    // The loaded rule's spec as the FORM would build it -- the baseline for the
    // form's dirty check (Save is disabled in edit mode until something changes).
    @State private var loadedFormJSON = ""

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
            } else if showGallery && !isEditing {
                recipeGallery
            } else {
            // Add mode reached the form from a recipe (or "Build your own") -- offer a
            // way back to the gallery. (Edit mode has Cancel instead, so gate on !isEditing.)
            // Just re-shows the gallery; the next recipe / "Build your own" resets the form.
            if !isEditing {
                HStack {
                    Button { showGallery = true } label: {
                        Label(Strings.t("rules.backToRecipes", default: "Recipes"), systemImage: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .help(Strings.t("rules.backToRecipesHelp", default: "Back to the recipe gallery"))
                    Spacer()
                }
            }
            // Name: the field's LABEL stays "Name (optional)"; its PROMPT (the in-field
            // placeholder) previews the auto-name -- the live sentence, which is what a
            // blank name falls back to. Type to override. Using `prompt:` (NOT the title
            // string) is load-bearing: in a Form the title renders as a WRAPPING row
            // LABEL that hides the editable field; a prompt stays an in-field placeholder.
            TextField(Strings.t("rules.namePlaceholder", default: "Name (optional)"),
                      text: $name, prompt: Text(namePlaceholder))
            // The rule AS AN EDITABLE SENTENCE -- a row of token pills, each a
            // tappable popover over the SAME @State the Pickers bound. The engine,
            // buildSpec, loadForEdit, canSubmit and the seeders are all unchanged.
            sentenceRow
            // chain/layout don't fit inline tokens: the effect-verb pill ("arrange
            // windows" / "do several things") is the stem, and the existing block
            // editor renders here beneath the row ("stem + block").
            if selectedEffect?.kind == "layout" {
                layoutEditor
            } else if selectedEffect?.kind == "chain" {
                chainEditor
            }
            // The engine's grammatical read-back now lives in the Name field's
            // placeholder (namePlaceholder) -- self-documenting and one row tighter.
            // The footgun warning stays INLINE (not only in the app pill's popover):
            // minimizing "it" on the GAINS-focus edge fires the instant you open the
            // app. Else, a from-trigger ("it") effect just gets the can't-Test note.
            if minimizeBecomesFootgun {
                Label(Strings.t("rules.minimizeBecomesWarning", default: "This acts on the app the moment it gains focus -- you'd never keep it open. Switch the transition to \"loses focus\" to act when you click away."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if leaveGoneFootgun {
                Label(leaveGoneWarningText, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if effectUsesTriggerContext {
                Label(Strings.t("rules.reactsToTrigger", default: "Reacts to its trigger -- no \"Test\" for it (the real event supplies \"it\")."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }   // end of the Form-mode (!advanced) fields

            // The error + Save/Cancel belong to the editor, not the gallery (whose
            // recipe cards are their own affordance) -- hide them while the gallery shows.
            if !(showGallery && !isEditing) {
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
                    // Editing: also require an actual change, so "Save changes" isn't
                    // offered for a no-op. Adding: canSubmit alone governs.
                    .disabled(!canSubmit || (isEditing && !hasPendingChanges))
                }
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
            // Switching TO solid wallpaper while ADDING a rule: default the display to
            // "the connecting display" when the trigger provides one, else a category.
            // Only seed an EMPTY field (mirrors minimizeAppName) -- so a recipe that
            // set an explicit display isn't clobbered. (Edit mode: loadForEdit owns it.)
            if editing == nil && wallpaperKinds.contains(selectedEffect?.kind ?? "") && solidDisplay.isEmpty {
                solidDisplay = (triggerProvides == "display") ? Self.triggerSentinel("display") : "external"
            }
            // Only seed an EMPTY field (mirrors the layout/chain seeders) -- so
            // switching between the app-target verbs (minimize <-> hide <-> quit)
            // keeps the app the user already chose.
            if editing == nil && appTargetKinds.contains(selectedEffect?.kind ?? "")
                && minimizeAppName.isEmpty {
                // From-trigger when the trigger publishes an app, else leave empty so
                // the user picks from the installed-apps list (no surprise auto-pick).
                minimizeAppName = (triggerProvides == "app") ? Self.triggerSentinel("app") : ""
                minimizeAppBundleId = ""
            }
            if editing == nil && selectedEffect?.kind == "moveAppToDisplay" {
                if moveApp.isEmpty {
                    moveApp = (triggerProvides == "app") ? Self.triggerSentinel("app") : ""
                    moveAppBundleId = ""
                }
                if moveDisplay.isEmpty {
                    moveDisplay = (triggerProvides == "display") ? Self.triggerSentinel("display") : (opts.layoutDisplays.first ?? "")
                }
            }
        }
        // If the trigger stops providing the entity a "from the trigger" param
        // needs, that param becomes unresolvable -- fall back to a valid literal so
        // the saved spec stays sound (applies in edit mode too).
        .onChange(of: triggerType) { _ in demoteOrphanedTriggerParams() }
        .onChange(of: transition) { _ in demoteOrphanedTriggerParams() }
        // Off for the whole form (inline fields AND popover content inherit it) so
        // a macOS autocorrect/autofill can't silently land in an identifier field
        // (an app name, URL, or a notify title -- the "android studio"-in-description
        // class of stray save). Propagates into .popover content via the environment.
        .autocorrectionDisabled()
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
        // Read the running apps ONCE per render -- appCandidates hits NSWorkspace + a
        // sort, and the menu uses it inside the per-placement ForEach below.
        let running = appCandidates
        if placements.isEmpty {
            Text(Strings.t("rules.noWindowsYet", default: "No windows yet -- add one, or capture your current arrangement."))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(placements.enumerated()), id: \.element.id) { i, p in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField(Strings.t("rules.appField", default: "App (e.g. Safari)"), text: $placements[i].app)
                    if !running.isEmpty {
                        Menu {
                            ForEach(running, id: \.self) { a in
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
                case "speak":
                    TextField(Strings.t("rules.speakField", default: "Text to speak aloud"), text: $chainSteps[i].speakText)
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

    // --- Read-back sentence ----------------------------------------------------
    // The Name field's PLACEHOLDER previews the rule's auto-name: the live sentence
    // ("When Slack loses focus, minimize it."), which is exactly what a blank name
    // falls back to -- self-documenting, shown grayed inside the labelled field. The
    // engine composes it (one source of truth with the list rows). Too incomplete to
    // read -> "" (an empty field under the "Name (optional)" label; the token pills,
    // each with its own placeholder, carry the guidance then).
    private var namePlaceholder: String { liveSentence }

    // Build the in-progress spec and ask the engine to phrase it. buildSpec() is
    // pure (no side effects) and returns nil until the rule is complete enough, so
    // an incomplete form yields "" (the placeholder). Cheap in-process eval.
    private var liveSentence: String {
        guard let spec = buildSpec(),
              let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return store.ruleSentence(json)
    }

    // --- Token sentence (the editable read-back) -------------------------------
    // The rule rendered as a wrapping row of pill tokens. Each pill opens a popover
    // bound to the SAME @State the old Pickers used, so buildSpec/loadForEdit/the
    // engine are untouched -- this is a pure presentation swap (see the plan). The
    // word ORDER mirrors rules.sentence (entity "value verb" / property "the label
    // verb value" / event-schedule lead); the engine read-back beneath is the
    // grammatical authority and a drift check.
    @ViewBuilder private var sentenceRow: some View {
        FlowLayout(hSpacing: 6, vSpacing: 8) {
            triggerTokens
            sentenceWord(",")
            effectTokens
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    // A plain (non-tappable) word in the sentence: "When"/"Every" lead, or an
    // inline connective ("the appearance", ",", "on", "do:").
    private func sentenceWord(_ s: String, lead: Bool = false) -> some View {
        Text(s).font(lead ? .title3 : .body).foregroundStyle(.primary)
    }

    @ViewBuilder private var triggerTokens: some View {
        sentenceWord(triggerType == "schedule"
            ? Strings.t("rules.lead.every", default: "Every")
            : Strings.t("rules.lead.when", default: "When"), lead: true)
        if isStateTrigger {
            if meta?.provides != nil {
                triggerValuePill          // entity: "<value> <verb>"
                verbPill
            } else {
                // "the <label>" is ENGLISH GRAMMAR -- an article this language needs and
                // Chinese does not. Concatenating it here hands a translator a sentence
                // they cannot fix (they would get "the 外观"), so the article lives in a
                // template the locale owns. `.lowercased()` is English morphology and a
                // no-op on a caseless script, which is the correct behaviour there.
                // Mirrors rules.clause.property, the engine-side authority.
                sentenceWord(String(format: Strings.t("rules.token.theProperty", default: "the %@"),
                                    (meta?.label ?? signal).lowercased()))
                verbPill
                triggerValuePill          // "the <label> <verb> <value>"
            }
        } else if triggerType == "event" {
            sentenceWord(Strings.t("rules.lead.on", default: "on"))
            TokenPill(text: eventName, help: Strings.t("rules.tokenTriggerHelp", default: "What this rule watches")) { triggerPopover }
        } else {                          // schedule
            schedulePill
        }
    }

    // The trigger's main value pill -- ALSO carries the trigger-type switcher in its
    // popover (the old "When" picker), so the reader edits the value and can repoint
    // the whole trigger from one place. Muted while empty.
    private var triggerValuePill: some View {
        TokenPill(text: stateValue.isEmpty ? valueTokenPlaceholder : stateValue,
                  muted: stateValue.isEmpty,
                  help: Strings.t("rules.tokenTriggerHelp", default: "What this rule watches")) { triggerPopover }
    }

    private var verbPill: some View {
        let verb = (transition == "becomes")
            ? (meta?.enterVerb ?? Strings.t("rules.becomes", default: "becomes"))
            : (meta?.leaveVerb ?? Strings.t("rules.leaves", default: "leaves"))
        return TokenPill(text: verb, help: Strings.t("rules.tokenVerbHelp", default: "When it fires")) { verbPopover }
    }

    private var schedulePill: some View {
        let label = scheduleMode == "everyMin"
            ? String(format: Strings.t("rules.token.everyMin", default: "%d minutes"), everyMin)
            : String(format: Strings.t("rules.token.dailyAt", default: "day at %@"), atTime)
        return TokenPill(text: label, help: Strings.t("rules.tokenTriggerHelp", default: "What this rule watches")) { triggerPopover }
    }

    @ViewBuilder private var effectTokens: some View {
        effectVerbPill
        let kind = selectedEffect?.kind ?? ""
        switch kind {
        case "notify":
            TokenPill(text: notifyTitle.isEmpty ? Strings.t("rules.token.aTitle", default: "a title")
                                                : "\u{201C}\(notifyTitle)\u{201D}",
                      muted: notifyTitle.isEmpty) { notifyPopover }
        case "runShortcut":
            TokenPill(text: shortcutName.isEmpty ? Strings.t("rules.token.aShortcut", default: "a Shortcut")
                                                 : "\u{201C}\(shortcutName)\u{201D}",
                      muted: shortcutName.isEmpty) { fieldPopover($shortcutName, Strings.t("rules.shortcutNameField", default: "Shortcut name (exactly as in the Shortcuts app)"), hint: Strings.t("rules.runShortcutHint", default: "Runs a macOS Shortcut -- the escape hatch to Focus/DND, volume, HomeKit, and anything Shortcuts can do.")) }
        case "openURL":
            TokenPill(text: openURLValue.isEmpty ? Strings.t("rules.token.aURL", default: "a URL") : openURLValue,
                      muted: openURLValue.isEmpty) { fieldPopover($openURLValue, Strings.t("rules.openURLField", default: "URL (https://… , or an app scheme like raycast://…)")) }
        case "speak":
            TokenPill(text: speakText.isEmpty ? Strings.t("rules.token.aLine", default: "a line")
                                              : "\u{201C}\(speakText)\u{201D}",
                      muted: speakText.isEmpty) { fieldPopover($speakText, Strings.t("rules.speakField", default: "Text to speak aloud")) }
        case "solidWallpaper":
            TokenPill(text: wallpaperSummary, anaphor: solidDisplay.hasPrefix("@trigger:")) { solidWallpaperEditor.frame(minWidth: 280) }
        case "setWallpaperImage":
            TokenPill(text: imageWallpaperSummary, muted: wallpaperImage.isEmpty,
                      anaphor: solidDisplay.hasPrefix("@trigger:")) { imageWallpaperEditor.frame(minWidth: 320) }
        case "moveAppToDisplay":
            if moveApp.hasPrefix("@trigger:") {
                TokenPill(text: Strings.t("rules.token.it", default: "it"), anaphor: true, help: itHelp) { moveAppEditor.frame(minWidth: 280) }
            } else {
                TokenPill(text: moveApp.isEmpty ? Strings.t("rules.token.anApp", default: "an app") : moveApp,
                          muted: moveApp.isEmpty) { moveAppEditor.frame(minWidth: 280) }
            }
            sentenceWord(Strings.t("rules.lead.to", default: "to"))
            if moveDisplay.hasPrefix("@trigger:") {
                TokenPill(text: Strings.t("rules.token.it", default: "it"), anaphor: true, help: itHelp) { moveDisplayEditor.frame(minWidth: 280) }
            } else {
                TokenPill(text: moveDisplay.isEmpty ? Strings.t("rules.token.aDisplay", default: "a display") : moveDisplay,
                          muted: moveDisplay.isEmpty) { moveDisplayEditor.frame(minWidth: 280) }
            }
        case "minimizeApp", "hideApp", "quitApp":
            if minimizeAppName.hasPrefix("@trigger:") {
                TokenPill(text: Strings.t("rules.token.it", default: "it"), anaphor: true, help: itHelp) { minimizeAppEditor.frame(minWidth: 300) }
            } else {
                TokenPill(text: minimizeAppName.isEmpty ? Strings.t("rules.token.anApp", default: "an app") : minimizeAppName,
                          muted: minimizeAppName.isEmpty) { minimizeAppEditor.frame(minWidth: 300) }
            }
        case "launchApp":
            // No "@trigger:" form -- launch always targets a literal installed app.
            TokenPill(text: launchAppName.isEmpty ? Strings.t("rules.token.anApp", default: "an app") : launchAppName,
                      muted: launchAppName.isEmpty) { launchAppEditor.frame(minWidth: 300) }
        case "setAppearance":
            TokenPill(text: appearanceModeLabel(appearanceMode)) { appearanceEditor.frame(minWidth: 200) }
        case "volume":
            TokenPill(text: volumeOpLabel(volumeOp)) { volumeEditor.frame(minWidth: 200) }
        case "mediaKey":
            TokenPill(text: mediaKeyLabel(mediaKeyName)) { mediaKeyEditor.frame(minWidth: 200) }
        case "layout", "chain":
            // "stem + block": the effect-verb pill ("arrange windows" / "do several
            // things") is the stem; the existing layoutEditor/chainEditor block
            // renders beneath the row (in the body), so no inline param pill here.
            EmptyView()
        default:
            EmptyView()   // lockScreen / command -- the verb pill says it all
        }
    }

    private var effectVerbPill: some View {
        TokenPill(text: effectVerbLabel(selectedEffect?.kind),
                  help: Strings.t("rules.tokenEffectHelp", default: "What to do when it fires")) { effectVerbPopover }
    }

    // --- token popovers (reuse the old field clusters) -------------------------
    @ViewBuilder private var triggerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(Strings.t("rules.when", default: "When"), selection: $triggerType) {
                ForEach(opts.signals, id: \.self) { Text(signalLabel($0)).tag("state:" + $0) }
                Text(Strings.t("rules.systemEvent", default: "System event")).tag("event")
                Text(Strings.t("rules.schedule", default: "Schedule")).tag("schedule")
            }
            Divider()
            if isStateTrigger {
                HStack {
                    // Typing a name directly invalidates a bundle id picked earlier (it
                    // named a different app) -- clear it so the engine matches the typed
                    // name, not a stale id. The chooser sets stateValue directly, bypassing
                    // this setter, so its paired bundle id survives.
                    TextField(valuePlaceholder, text: Binding(
                        get: { stateValue },
                        set: { stateValue = $0; stateValueBundleId = "" }))
                    if signalUsesBundleId {
                        // An app-identity value (frontmost / running app): pick from ALL
                        // installed apps (searchable), not just running ones -- so a rule can
                        // watch for an app that's closed now. The chooser stores the display
                        // name in stateValue AND the bundle id in stateValueBundleId; the
                        // engine matches on the bundle id (stable), the name as a fallback.
                        Button { showFrontmostPicker.toggle() } label: { Image(systemName: "list.bullet") }
                            .buttonStyle(.borderless).frame(width: 32)
                            .help(Strings.t("rules.pickInstalledApp", default: "Pick an installed app"))
                            .popover(isPresented: $showFrontmostPicker, arrowEdge: .bottom) {
                                AppTargetChooser(
                                    name: $stateValue, bundleId: $stateValueBundleId,
                                    sentinel: "", triggerProvidesApp: false, fromTriggerLabel: "",
                                    warning: nil,
                                    hint: Strings.t("rules.frontmostPickHint", default: "Pick any installed app -- it needn't be running now."))
                                    .frame(width: 300).padding(12)
                            }
                    } else if !candidates.isEmpty {
                        Menu {
                            ForEach(candidates, id: \.self) { c in Button(c) { stateValue = c; stateValueBundleId = "" } }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).frame(width: 32)
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
            } else {
                Picker(Strings.t("rules.mode", default: "Mode"), selection: $scheduleMode) {
                    Text(Strings.t("rules.everyNMinutes", default: "Every N minutes")).tag("everyMin")
                    Text(Strings.t("rules.dailyAt", default: "Daily at")).tag("at")
                }
                if scheduleMode == "everyMin" {
                    Stepper(String(format: Strings.t("rules.everyMinStepper", default: "Every %d min"), everyMin), value: $everyMin, in: 1...1440)
                } else {
                    TextField(Strings.t("rules.hhmm", default: "HH:MM"), text: $atTime)
                    if !HHMM.isValid(atTime) {
                        Text(Strings.t("rules.hhmmHint", default: "Enter a 24-hour time like 09:00 or 23:30."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(minWidth: 300)
    }

    // The verb popover -- each edge with its TIMING subtitle underneath (the
    // footgun-killer: "gains focus -- the moment you switch to it" vs "loses focus
    // -- the moment you click away"). Timing comes from signals.meta (enterWhen/
    // leaveWhen); a signal without it shows just the verb.
    @ViewBuilder private var verbPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            transitionRow("becomes",
                          meta?.enterVerb ?? Strings.t("rules.becomes", default: "becomes"),
                          meta?.enterWhen)
            Divider().padding(.vertical, 3)
            transitionRow("leaves",
                          meta?.leaveVerb ?? Strings.t("rules.leaves", default: "leaves"),
                          meta?.leaveWhen)
        }
        .frame(minWidth: 240)
    }

    private func transitionRow(_ edge: String, _ verb: String, _ when: String?) -> some View {
        Button { transition = edge } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.tint)
                    .opacity(transition == edge ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verb).font(.body)
                        .foregroundStyle(transition == edge ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if let when, !when.isEmpty {
                        Text(when).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var effectVerbPopover: some View {
        Picker(Strings.t("rules.do", default: "Do"), selection: $effectId) {
            ForEach(opts.effects) { Text($0.label).tag($0.id) }
        }
        .pickerStyle(.inline).labelsHidden().frame(minWidth: 240)
    }

    @ViewBuilder private var notifyPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(Strings.t("rules.notifyTitleField", default: "Notification title"), text: $notifyTitle)
            TextField(Strings.t("rules.notifyTextField", default: "Notification text (optional)"), text: $notifyText)
            Picker(Strings.t("rules.showAs", default: "Show as"), selection: $notifyChannel) {
                Text(Strings.t("rules.systemNotification", default: "System notification")).tag("system")
                Text(Strings.t("rules.inAppBanner", default: "In-app banner")).tag("app")
            }
            // The one non-obvious behavior: "System" silently falls back to the
            // in-app banner on an unpackaged/dev run. Keep this surfaced.
            if notifyChannel == "system" {
                Text(Strings.t("rules.notifyChannelHint", default: "Appears in Notification Center -- persists in history, shows on the lock screen, and respects Focus. Needs the packaged app; a dev run falls back to the in-app banner."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 300)
    }

    // A one-field text popover (runShortcut name / openURL url), with an optional
    // discoverability hint beneath (e.g. "what is a Shortcut effect for").
    @ViewBuilder private func fieldPopover(_ text: Binding<String>, _ placeholder: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: text)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 300)
    }

    // --- token labels ----------------------------------------------------------
    private func effectVerbLabel(_ kind: String?) -> String {
        switch kind {
        case "notify":         return Strings.t("rules.verb.notify", default: "notify")
        case "lockScreen":     return Strings.t("rules.verb.lock", default: "lock the screen")
        case "startScreensaver": return Strings.t("rules.verb.screensaver", default: "start the screensaver")
        case "emptyTrash":     return Strings.t("rules.verb.emptyTrash", default: "empty the Trash")
        case "eject":          return Strings.t("rules.verb.eject", default: "eject external disks")
        case "setAppearance":  return Strings.t("rules.verb.appearance", default: "set appearance")
        case "volume":         return Strings.t("rules.verb.volume", default: "volume")
        case "mediaKey":       return Strings.t("rules.verb.media", default: "media")
        case "solidWallpaper", "setWallpaperImage": return Strings.t("rules.verb.wallpaper", default: "set wallpaper")
        case "moveAppToDisplay": return Strings.t("rules.verb.move", default: "move")
        case "minimizeApp":    return Strings.t("rules.verb.minimize", default: "minimize")
        case "hideApp":        return Strings.t("rules.verb.hide", default: "hide")
        case "quitApp":        return Strings.t("rules.verb.quit", default: "quit")
        case "launchApp":      return Strings.t("rules.verb.launchApp", default: "open")
        case "openURL":        return Strings.t("rules.verb.open", default: "open")
        case "speak":          return Strings.t("rules.verb.speak", default: "say")
        case "runShortcut":    return Strings.t("rules.verb.runShortcut", default: "run Shortcut")
        case "layout":         return Strings.t("rules.verb.layout", default: "arrange windows")
        case "chain":          return Strings.t("rules.verb.chain", default: "do several things")
        default:               return selectedEffect?.label ?? (kind ?? "")   // command -> "Run: <label>"
        }
    }

    private func colorLabel(_ hex: String) -> String {
        switch hex.uppercased() {
        case "#FFFFFF": return Strings.t("rules.colorWhite", default: "White").lowercased()
        case "#F2F2F2": return Strings.t("rules.colorLightGray", default: "Light gray").lowercased()
        case "#808080": return Strings.t("rules.colorMidGray", default: "Mid gray").lowercased()
        case "#000000": return Strings.t("rules.colorBlack", default: "Black").lowercased()
        default:        return hex
        }
    }

    // The display half of a wallpaper summary ("it" / "external displays" / a name),
    // shared by both the solid-color and image wallpaper pills.
    private var wallpaperWhere: String {
        if solidDisplay.hasPrefix("@trigger:") { return Strings.t("rules.token.it", default: "it") }
        switch solidDisplay {
        case "all":      return Strings.t("rules.solidAllDisplaysShort", default: "all displays")
        case "external": return Strings.t("rules.solidExternalShort", default: "external displays")
        case "primary":  return Strings.t("rules.solidMainShort", default: "the main display")
        default:         return solidDisplay.isEmpty ? Strings.t("rules.token.aDisplay", default: "a display") : solidDisplay
        }
    }

    private var wallpaperSummary: String {
        String(format: Strings.t("rules.token.wallpaperSummary", default: "%1$@ on %2$@"), colorLabel(solidColor), wallpaperWhere)
    }

    private var imageWallpaperSummary: String {
        let name = wallpaperImage.isEmpty
            ? Strings.t("rules.token.anImage", default: "an image")
            : URL(fileURLWithPath: wallpaperImage).lastPathComponent
        return String(format: Strings.t("rules.token.wallpaperSummary", default: "%1$@ on %2$@"), name, wallpaperWhere)
    }

    private var valueTokenPlaceholder: String {
        switch meta?.provides {
        case "app":     return Strings.t("rules.token.anApp", default: "an app")
        case "display": return Strings.t("rules.token.aDisplay", default: "a display")
        default:        return (meta?.valueLabel ?? Strings.t("rules.token.value", default: "a value")).lowercased()
        }
    }

    private var itHelp: String {
        Strings.t("rules.token.itHelp", default: "The app/display from the trigger -- resolved when the rule fires")
    }

    // True when an effect param is bound to the trigger (an "it" pill is showing) --
    // such a rule reacts to its trigger and can't be Test-fired in isolation.
    private var effectUsesTriggerContext: Bool {
        (appTargetKinds.contains(selectedEffect?.kind ?? "") && minimizeAppName.hasPrefix("@trigger:"))
            || (wallpaperKinds.contains(selectedEffect?.kind ?? "") && solidDisplay.hasPrefix("@trigger:"))
            || (selectedEffect?.kind == "moveAppToDisplay" && (moveApp.hasPrefix("@trigger:") || moveDisplay.hasPrefix("@trigger:")))
    }

    // The exact dangerous combo the redesign exists to prevent: minimize/hide/quit
    // the app FROM THE TRIGGER on the GAINS-focus edge -- it fires the instant you
    // open the app, so you'd never keep it open. Warrants an inline warning (not
    // just the one inside the app pill's popover).
    private var minimizeBecomesFootgun: Bool {
        appTargetKinds.contains(selectedEffect?.kind ?? "")
            && minimizeAppName.hasPrefix("@trigger:")
            && signal == "frontmostApp" && transition == "becomes"
    }

    // A from-trigger effect bound on the LEAVE edge of a signal whose entity is GONE
    // then (runningApps quits, displaysPresent disconnects) -- the effect would act on
    // something that no longer exists and always fail. Data-driven via the signal's
    // `goneOnLeave` meta, not a hardcoded signal name (mirrors signalUsesBundleId).
    // frontmostApp "loses focus" is NOT flagged: that leave edge keeps the app alive
    // (the flagship minimize-on-focus-loss case). Distinct from minimizeBecomesFootgun
    // (a frontmost GAINS-focus trap) -- the two never overlap (different signal/edge).
    private var leaveGoneFootgun: Bool {
        isStateTrigger && (meta?.goneOnLeave ?? false)
            && transition == "leaves" && effectUsesTriggerContext
    }

    // The leave-edge warning, phrased from the signal's own meta (the entity noun +
    // its verbs) so it reads for any such signal: "On 'quits' the app is already gone
    // ... switch to 'launches'" / "On 'disconnects' the display is already gone ...".
    private var leaveGoneWarningText: String {
        let field = meta?.provides ?? ""
        let noun = Strings.t("rules.triggerField." + field, default: field.isEmpty ? "it" : field)
        let leaveVerb = meta?.leaveVerb ?? Strings.t("rules.leaves", default: "leaves")
        let enterVerb = meta?.enterVerb ?? Strings.t("rules.becomes", default: "becomes")
        return String(format: Strings.t("rules.leaveGoneWarning",
            default: "On \"%1$@\" the %2$@ is already gone, so this effect has nothing to act on. Switch the transition to \"%3$@\" to act while it's still there."),
            leaveVerb, noun, enterVerb)
    }

    // --- Recipe gallery (the "New rule" landing) -------------------------------
    // One starter rule. Picking it pre-fills the form (it is NOT a separate object
    // type -- applyRecipe just seeds the same @State the form already edits), then
    // drops the user into the editor to finish the user-specific parts (which app,
    // which display). Gated by `signalNeeded`: a recipe whose trigger signal the
    // engine doesn't offer this build is hidden rather than shown as a dead end.
    private struct RuleRecipe: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let subtitle: String
        let signalNeeded: String?   // a state signal that must exist (nil = always available)
    }

    private var recipes: [RuleRecipe] {
        [
            RuleRecipe(id: "whiten_eink", icon: "display", tint: .blue,
                       title: Strings.t("rules.recipe.whitenEink.title", default: "Whiten an e-ink monitor"),
                       subtitle: Strings.t("rules.recipe.whitenEink.sub", default: "White wallpaper the moment a display connects."),
                       signalNeeded: "displaysPresent"),
            RuleRecipe(id: "minimize_away", icon: "macwindow", tint: .indigo,
                       title: Strings.t("rules.recipe.minimizeAway.title", default: "Minimize on switch-away"),
                       subtitle: Strings.t("rules.recipe.minimizeAway.sub", default: "Minimize an app the moment you click away from it."),
                       signalNeeded: "frontmostApp"),
            RuleRecipe(id: "notify_wake", icon: "bell.badge", tint: .orange,
                       title: Strings.t("rules.recipe.notifyWake.title", default: "Notify on wake"),
                       subtitle: Strings.t("rules.recipe.notifyWake.sub", default: "Show a notification when the Mac wakes."),
                       signalNeeded: nil),
            RuleRecipe(id: "arrange_dock", icon: "square.grid.2x2", tint: .teal,
                       title: Strings.t("rules.recipe.arrangeDock.title", default: "Arrange windows on dock"),
                       subtitle: Strings.t("rules.recipe.arrangeDock.sub", default: "Snap your windows into place when a display connects."),
                       signalNeeded: "displaysPresent"),
            RuleRecipe(id: "dark_battery", icon: "battery.25", tint: .green,
                       title: Strings.t("rules.recipe.darkBattery.title", default: "Dark wallpaper on battery"),
                       subtitle: Strings.t("rules.recipe.darkBattery.sub", default: "Switch to a black wallpaper when you unplug."),
                       signalNeeded: "powerSource"),
            RuleRecipe(id: "lock_schedule", icon: "lock", tint: .gray,
                       title: Strings.t("rules.recipe.lockSchedule.title", default: "Lock on a schedule"),
                       subtitle: Strings.t("rules.recipe.lockSchedule.sub", default: "Lock the screen every day at a set time."),
                       signalNeeded: nil),
            RuleRecipe(id: "dark_evening", icon: "moon.fill", tint: .purple,
                       title: Strings.t("rules.recipe.darkEvening.title", default: "Dark mode at night"),
                       subtitle: Strings.t("rules.recipe.darkEvening.sub", default: "Switch to Dark appearance every evening at a set time."),
                       signalNeeded: nil),
        ].filter { $0.signalNeeded == nil || opts.signals.contains($0.signalNeeded!) }
    }

    @ViewBuilder private var recipeGallery: some View {
        Text(Strings.t("rules.startFromRecipe", default: "Start from a recipe")).font(.headline)
        Text(Strings.t("rules.startFromRecipeHint", default: "Pick a starter, then fill in the details -- or build your own."))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(recipes) { recipeCard($0) }
        }
        Button { resetForm(); showGallery = false } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "plus")
                Text(Strings.t("rules.buildYourOwn", default: "Build your own -- start from a blank rule"))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func recipeCard(_ r: RuleRecipe) -> some View {
        Button { applyRecipe(r.id); showGallery = false } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: r.icon)
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(r.tint))
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.callout).fontWeight(.semibold).foregroundStyle(.primary)
                    Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Seed the form @State from a recipe, then the card flips showGallery off so the
    // (now pre-filled) editor appears. resetForm() first for a clean slate; the
    // onChange(effectId) seeders are guarded on isEmpty, so the explicit values set
    // here survive. Value-bearing recipes that need a user choice (which app) leave
    // stateValue blank for them to fill; the rest are complete and read immediately.
    private func applyRecipe(_ id: String) {
        resetForm()
        switch id {
        case "whiten_eink":
            triggerType = "state:displaysPresent"; transition = "becomes"
            stateValue = opts.signalCandidates["displaysPresent"]?.first ?? ""
            effectId = "solidWallpaper"; solidColor = "#FFFFFF"; solidDisplay = Self.triggerSentinel("display")
        case "minimize_away":
            triggerType = "state:frontmostApp"; transition = "leaves"
            stateValue = ""   // the user picks the app they care about
            effectId = "minimizeApp"; minimizeAppName = Self.triggerSentinel("app")
        case "notify_wake":
            triggerType = "event"; eventName = "wake"
            effectId = "notify"; notifyTitle = AppInfo.displayName; notifyText = ""; notifyChannel = "system"
        case "arrange_dock":
            triggerType = "state:displaysPresent"; transition = "becomes"
            stateValue = opts.signalCandidates["displaysPresent"]?.first ?? ""
            effectId = "layout"   // onChange(effectId) seeds a first placement
        case "dark_battery":
            triggerType = "state:powerSource"; transition = "becomes"; stateValue = "battery"
            effectId = "solidWallpaper"; solidColor = "#000000"; solidDisplay = "all"
        case "lock_schedule":
            triggerType = "schedule"; scheduleMode = "at"; atTime = "18:00"
            effectId = "lockScreen"
        case "dark_evening":
            triggerType = "schedule"; scheduleMode = "at"; atTime = "20:00"
            effectId = "setAppearance"; appearanceMode = "dark"
        default:
            break
        }
    }

    // --- appearance / volume / media sub-pickers (grouped rules atoms) ---------
    // Each hosts one inline enum picker in the token pill's popover; the pill text
    // echoes the current choice. Labels are shared by the pill and the picker rows.
    private func appearanceModeLabel(_ m: String) -> String {
        switch m {
        case "light":  return Strings.t("rules.appearance.light", default: "Light")
        case "toggle": return Strings.t("rules.appearance.toggle", default: "Toggle")
        default:       return Strings.t("rules.appearance.dark", default: "Dark")
        }
    }
    private func volumeOpLabel(_ op: String) -> String {
        switch op {
        case "down": return Strings.t("rules.volume.down", default: "Down")
        case "mute": return Strings.t("rules.volume.mute", default: "Mute")
        default:     return Strings.t("rules.volume.up", default: "Up")
        }
    }
    private func mediaKeyLabel(_ k: String) -> String {
        switch k {
        case "next":     return Strings.t("rules.media.next", default: "Next track")
        case "previous": return Strings.t("rules.media.previous", default: "Previous track")
        default:         return Strings.t("rules.media.playpause", default: "Play / Pause")
        }
    }
    @ViewBuilder private var appearanceEditor: some View {
        Picker(Strings.t("rules.appearance.label", default: "Appearance"), selection: $appearanceMode) {
            Text(appearanceModeLabel("dark")).tag("dark")
            Text(appearanceModeLabel("light")).tag("light")
            Text(appearanceModeLabel("toggle")).tag("toggle")
        }.pickerStyle(.inline).labelsHidden()
    }
    @ViewBuilder private var volumeEditor: some View {
        Picker(Strings.t("rules.volume.label", default: "Volume"), selection: $volumeOp) {
            Text(volumeOpLabel("up")).tag("up")
            Text(volumeOpLabel("down")).tag("down")
            Text(volumeOpLabel("mute")).tag("mute")
        }.pickerStyle(.inline).labelsHidden()
    }
    @ViewBuilder private var mediaKeyEditor: some View {
        Picker(Strings.t("rules.media.label", default: "Media"), selection: $mediaKeyName) {
            Text(mediaKeyLabel("playpause")).tag("playpause")
            Text(mediaKeyLabel("next")).tag("next")
            Text(mediaKeyLabel("previous")).tag("previous")
        }.pickerStyle(.inline).labelsHidden()
    }

    // The color + display editor (shown when the effect is "solidWallpaper").
    // Color is a preset (there's no NSColorWell idiom in the app); the display can
    // be a literal monitor, a category, or -- on a "<display> connects" rule --
    // "the connecting display" (resolved from the trigger at fire time).
    @ViewBuilder private var solidWallpaperEditor: some View {
        Picker(Strings.t("rules.solidWallpaperColor", default: "Color"), selection: $solidColor) {
            Text(Strings.t("rules.colorWhite", default: "White")).tag("#FFFFFF")
            Text(Strings.t("rules.colorLightGray", default: "Light gray")).tag("#F2F2F2")
            Text(Strings.t("rules.colorMidGray", default: "Mid gray")).tag("#808080")
            Text(Strings.t("rules.colorBlack", default: "Black")).tag("#000000")
        }
        wallpaperDisplayPicker
    }

    // The image + display editor (shown when the effect is "setWallpaperImage"):
    // pick a photo file (path field + Choose...) plus the display(s) to set it on --
    // the SAME display model as solidWallpaper (literal / category / the connecting
    // display), so it reuses wallpaperDisplayPicker and the solidDisplay @State.
    @ViewBuilder private var imageWallpaperEditor: some View {
        HStack {
            TextField(Strings.t("rules.wallpaperImageField", default: "Image file path"), text: $wallpaperImage)
            Button(Strings.t("rules.choose", default: "Choose...")) { chooseWallpaperImage() }
        }
        if let w = wallpaperImageWarning {
            Text(w).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        wallpaperDisplayPicker
    }

    // The "Apply to" display picker -- shared by both wallpaper effects.
    @ViewBuilder private var wallpaperDisplayPicker: some View {
        Picker(Strings.t("rules.solidWallpaperDisplay", default: "Apply to"), selection: $solidDisplay) {
            if triggerProvides == "display" {
                Text(triggerOptionLabel("display")).tag(Self.triggerSentinel("display"))
            }
            Text(Strings.t("rules.solidAllDisplays", default: "All displays")).tag("all")
            Text(Strings.t("rules.solidExternalDisplays", default: "External displays only")).tag("external")
            Text(Strings.t("rules.solidMainDisplay", default: "Main display only")).tag("primary")
            ForEach(solidDisplayNames, id: \.self) { Text($0).tag($0) }
        }
    }

    // Advisory: the chosen image path doesn't exist right now (renamed/moved). The
    // rule still saves -- the file may exist when it fires -- but warn on exact path.
    private var wallpaperImageWarning: String? {
        let p = wallpaperImage.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !FileManager.default.fileExists(atPath: p) else { return nil }
        return Strings.t("rules.wallpaperImageMissing", default: "That file isn't there right now -- the path must exist when the rule fires.")
    }

    // NSOpenPanel to pick the wallpaper image file (a path the native setWallpaper reads).
    private func chooseWallpaperImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.t("rules.choose", default: "Choose...")
        if panel.runModal() == .OK, let url = panel.url { wallpaperImage = url.path }
    }

    // Literal display names for the wallpaper picker: currently-connected displays,
    // plus the rule's own saved display if it isn't connected now (so editing an
    // undocked rule doesn't silently drop it). Categories + the sentinel render apart.
    private var solidDisplayNames: [String] {
        var out = opts.layoutDisplays
        let cur = solidDisplay
        let reserved: Set<String> = ["all", "external", "primary"]
        if !cur.hasPrefix("@trigger:") && !reserved.contains(cur) && !cur.isEmpty && !out.contains(cur) {
            out.insert(cur, at: 0)
        }
        return out
    }

    // The app chooser (shown for minimizeApp / hideApp / quitApp -- they differ only
    // in the verb, so they share this). Pick from ALL installed apps (not just
    // running, so "Quit Slack" is authorable while Slack is closed); selecting one
    // stores its BUNDLE ID as the canonical match key. Or -- when the trigger
    // publishes one -- "the app from the trigger" (resolved at fire time; natural
    // pairing: "Frontmost app loses focus" -> minimize the app you clicked away from).
    @ViewBuilder private var minimizeAppEditor: some View {
        AppTargetChooser(
            name: $minimizeAppName, bundleId: $minimizeAppBundleId,
            sentinel: Self.triggerSentinel("app"),
            triggerProvidesApp: triggerProvides == "app",
            fromTriggerLabel: triggerOptionLabel("app"),
            // The footgun the user hit: acting on "the app from the trigger" on the
            // GAINS-focus edge fires the instant you open it. Flag it over the hint.
            warning: (minimizeAppName.hasPrefix("@trigger:") && signal == "frontmostApp" && transition == "becomes")
                ? Strings.t("rules.minimizeBecomesWarning", default: "This acts on the app the moment it gains focus -- you'd never keep it open. Switch the transition to \"loses focus\" to act when you click away.")
                : nil,
            hint: Strings.t("rules.minimizeAppHint", default: "Targets the app's front window. Pair with \"Frontmost app loses focus\" to act the moment you click away."))
    }

    // moveAppToDisplay's app chooser (same installed-apps picker + the from-trigger
    // option; no minimize footgun warning).
    @ViewBuilder private var moveAppEditor: some View {
        AppTargetChooser(
            name: $moveApp, bundleId: $moveAppBundleId,
            sentinel: Self.triggerSentinel("app"),
            triggerProvidesApp: triggerProvides == "app",
            fromTriggerLabel: triggerOptionLabel("app"),
            warning: nil,
            hint: Strings.t("rules.moveAppHint", default: "Moves the app's windows to the chosen display."))
    }

    // launchApp's app chooser. Pick any INSTALLED app to open -- its bundle id is the
    // launch key, so (unlike minimize/move, which act on a running app by name or id) a
    // manually-typed name isn't enough; the picker must resolve a bundle id. No "from
    // the trigger" option: you can't meaningfully launch the app a trigger reacts to.
    @ViewBuilder private var launchAppEditor: some View {
        AppTargetChooser(
            name: $launchAppName, bundleId: $launchAppBundleId,
            sentinel: "", triggerProvidesApp: false, fromTriggerLabel: "",
            // A typed name with no resolved bundle id can't launch -- flag it (canSubmit
            // also blocks save until a real app is picked from the list).
            warning: (!launchAppName.isEmpty && launchAppBundleId.isEmpty)
                ? Strings.t("rules.launchAppNeedsBundleId", default: "Pick an app from the list -- a typed name alone can't open an app.")
                : nil,
            hint: Strings.t("rules.launchAppHint", default: "Opens (launches) the app when the rule fires -- e.g. open Slack every day at 9am."))
    }

    @ViewBuilder private var moveDisplayEditor: some View {
        Picker(Strings.t("rules.moveToDisplay", default: "To display"), selection: $moveDisplay) {
            if triggerProvides == "display" {
                Text(triggerOptionLabel("display")).tag(Self.triggerSentinel("display"))
            }
            ForEach(moveDisplayNames, id: \.self) { Text($0).tag($0) }
        }
    }
    private var moveDisplayNames: [String] {
        var out = opts.layoutDisplays
        if !moveDisplay.hasPrefix("@trigger:") && !moveDisplay.isEmpty && !out.contains(moveDisplay) { out.insert(moveDisplay, at: 0) }
        return out
    }

    // The effect kinds that target an app (share the chooser + the `app`/`appBundleId`
    // params). Named "...ByName" historically; matching is now bundle-id-first.
    // The two wallpaper effects share the solidDisplay @State + the display picker.
    private let wallpaperKinds: Set<String> = ["solidWallpaper", "setWallpaperImage"]

    // --- Generic "from the trigger" plumbing (de-hardcoded) --------------------
    // The context field the selected trigger publishes ("display" | "app"), read
    // from the signal's OWN `provides` meta -- the editor never names a signal.
    private var triggerProvides: String? { isStateTrigger ? meta?.provides : nil }
    // The sentinel an effect param stores to bind to a trigger field (mirrors
    // effects.lua's "@trigger:<field>" + effects.resolveParam).
    private static func triggerSentinel(_ field: String) -> String { "@trigger:\(field)" }
    // The from-trigger option label, e.g. "The display from the trigger". The EDGE
    // (gains/loses) is conveyed by the Transition picker, so it isn't repeated here.
    private func triggerOptionLabel(_ field: String) -> String {
        // Localize the noun (display/app) rather than interpolating the raw `provides`
        // key -- otherwise a zh-Hans build shows "来自触发器的 display". Unknown fields
        // fall back to the raw key (still readable English) until a noun is added.
        let noun = Strings.t("rules.triggerField." + field, default: field)
        return String(format: Strings.t("rules.fromTrigger", default: "The %@ from the trigger"), noun)
    }

    private func demoteOrphanedTriggerParams() {
        // Switching the trigger SIGNAL to one that doesn't match by bundle id drops the
        // app's bundle id -- it named a pick the new signal can't match on (belt to the
        // buildSpec/engine gates). Both app signals keep it, so frontmost<->running
        // doesn't lose the chosen app.
        if !signalUsesBundleId { stateValueBundleId = "" }
        if wallpaperKinds.contains(selectedEffect?.kind ?? "")
            && solidDisplay.hasPrefix("@trigger:") && triggerProvides != "display" {
            solidDisplay = "external"
        }
        if appTargetKinds.contains(selectedEffect?.kind ?? "")
            && minimizeAppName.hasPrefix("@trigger:") && triggerProvides != "app" {
            minimizeAppName = ""; minimizeAppBundleId = ""   // back to "pick an app"
        }
        if selectedEffect?.kind == "moveAppToDisplay" {
            if moveApp.hasPrefix("@trigger:") && triggerProvides != "app" { moveApp = ""; moveAppBundleId = "" }
            if moveDisplay.hasPrefix("@trigger:") && triggerProvides != "display" { moveDisplay = opts.layoutDisplays.first ?? "" }
        }
    }

    private func chainStepComplete(_ s: ChainStep) -> Bool {
        switch s.kind {
        case "notify":      return !s.notifyTitle.trimmingCharacters(in: .whitespaces).isEmpty
        case "speak":       return !s.speakText.trimmingCharacters(in: .whitespaces).isEmpty
        case "runShortcut": return !s.shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        case "openURL":     return !s.url.trimmingCharacters(in: .whitespaces).isEmpty
        case "lockScreen", "startScreensaver", "emptyTrash", "eject":  return true
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
        s.speakText = d["text"] as? String ?? ""
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
    // Does the selected signal match by a stored bundle id (the app-identity
    // signals)? Drives the installed-apps picker + the on.bundleId persistence --
    // read from the signal's OWN meta, so the form never names a signal (the engine
    // owns the truth via sig.bundleIdMatch; this just mirrors it host-side).
    private var signalUsesBundleId: Bool { meta?.bundleIdMatch ?? false }
    private func signalLabel(_ s: String) -> String { opts.signalMeta[s]?.label ?? s }
    private var valuePlaceholder: String {
        let label = meta?.valueLabel ?? Strings.t("rules.value", default: "Value")
        let ex = meta?.example ?? ""
        return ex.isEmpty ? label : String(format: Strings.t("rules.valueExample", default: "%1$@ (e.g. %2$@)"), label, ex)
    }

    // The layout editor's app picker draws from the running apps -- sourced directly
    // from the host-UI catalog (sorted, deduped), the same way the chooser + the
    // generic appList option do. (It used to read the frontmostApp signal's candidates,
    // an odd dependency on a TRIGGER signal that survived only here once the app-target
    // effect editors moved to AppTargetChooser.)
    private var appCandidates: [String] { AppCatalog.runningApps().map(\.name) }

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

    private var canSubmit: Bool {
        if advanced {
            return !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if triggerType == "schedule", scheduleMode == "at", !HHMM.isValid(atTime) {
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
        if selectedEffect?.kind == "speak" {
            return !speakText.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "solidWallpaper" {
            return !solidDisplay.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "setWallpaperImage" {
            return !wallpaperImage.trimmingCharacters(in: .whitespaces).isEmpty
                && !solidDisplay.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if appTargetKinds.contains(selectedEffect?.kind ?? "") {
            return !minimizeAppName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "launchApp" {
            // Require the bundle id (not just the name) -- launch needs it.
            return !launchAppBundleId.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "moveAppToDisplay" {
            return !moveApp.trimmingCharacters(in: .whitespaces).isEmpty
                && !moveDisplay.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if selectedEffect?.kind == "chain" {
            return chainSteps.contains { chainStepComplete($0) }
        }
        return selectedEffect != nil
    }

    // The form's CURRENT spec as canonical JSON (sorted keys -> stable string),
    // for the dirty check. Built from @State via buildSpec, so it compares like
    // with like against loadedFormJSON (the same builder ran it at load time);
    // "" when the form is too incomplete to build (which canSubmit also blocks).
    private func formSpecJSON() -> String {
        guard let spec = buildSpec(),
              let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // In EDIT mode, has anything actually changed from the loaded rule? Drives the
    // Save button's disabled state so "Save changes" isn't offered for a no-op.
    // JSON mode uses its own seed comparison; the form uses the spec baseline.
    private var hasPendingChanges: Bool {
        advanced ? (jsonText != jsonSeed) : (formSpecJSON() != loadedFormJSON)
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
        stateValueBundleId = ""
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
        speakText = ""
        wallpaperImage = ""
        solidColor = "#FFFFFF"
        solidDisplay = ""
        moveApp = ""; moveDisplay = ""
        minimizeAppName = ""
        minimizeAppBundleId = ""; moveAppBundleId = ""
        launchAppName = ""; launchAppBundleId = ""
        appearanceMode = "dark"; volumeOp = "up"; mediaKeyName = "playpause"
        formError = nil
        advanced = false
        jsonText = ""
        jsonSeed = ""
        loadedFormJSON = ""   // add mode uses canSubmit, not the dirty baseline
        formDirty = false
        showGallery = true   // a fresh "New rule" lands on the recipe gallery
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
            // Only an app-identity signal carries a bundle id; ignore a stray one on
            // any other signal (don't round-trip a corrupted/dead-rule value). Gated on
            // the signal's OWN capability, not a hardcoded name.
            stateValueBundleId = (opts.signalMeta[sig]?.bundleIdMatch ?? false)
                ? (on["bundleId"] as? String ?? "") : ""
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
        placements = []; chainSteps = []; shortcutName = ""; openURLValue = ""; speakText = ""
        wallpaperImage = ""; solidColor = "#FFFFFF"; solidDisplay = ""; minimizeAppName = ""
        moveApp = ""; moveDisplay = ""
        minimizeAppBundleId = ""; moveAppBundleId = ""
        launchAppName = ""; launchAppBundleId = ""
        appearanceMode = "dark"; volumeOp = "up"; mediaKeyName = "playpause"
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
        } else if kind == "speak" {
            effectId = "speak"
            speakText = effect["text"] as? String ?? ""
        } else if kind == "solidWallpaper" {
            effectId = "solidWallpaper"
            solidColor = effect["color"] as? String ?? "#FFFFFF"
            solidDisplay = effect["display"] as? String ?? "external"
        } else if kind == "setWallpaperImage" {
            effectId = "setWallpaperImage"
            wallpaperImage = effect["image"] as? String ?? ""
            solidDisplay = effect["display"] as? String ?? "external"
        } else if kind == "moveAppToDisplay" {
            effectId = "moveAppToDisplay"
            moveApp = effect["app"] as? String ?? ""
            moveAppBundleId = effect["appBundleId"] as? String ?? ""
            moveDisplay = effect["display"] as? String ?? ""
        } else if let k = kind, appTargetKinds.contains(k) {
            effectId = k
            minimizeAppName = effect["app"] as? String ?? ""
            minimizeAppBundleId = effect["appBundleId"] as? String ?? ""
        } else if kind == "launchApp" {
            effectId = "launchApp"
            launchAppName = effect["app"] as? String ?? ""
            launchAppBundleId = effect["appBundleId"] as? String ?? ""
        } else if kind == "setAppearance" {
            effectId = "setAppearance"
            appearanceMode = effect["mode"] as? String ?? "dark"
        } else if kind == "volume" {
            effectId = "volume"
            volumeOp = effect["op"] as? String ?? "up"
        } else if kind == "mediaKey" {
            effectId = "mediaKey"
            mediaKeyName = effect["key"] as? String ?? "playpause"
        } else if kind == "lockScreen" {
            effectId = "lockScreen"
        } else if kind == "startScreensaver" {
            effectId = "startScreensaver"
        } else if kind == "emptyTrash" {
            effectId = "emptyTrash"
        } else if kind == "eject" {
            effectId = "eject"
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
        // A loaded sentinel orphaned by its trigger (e.g. a JSON-authored
        // "@trigger:display" on a non-display rule) -> demote to a valid literal so
        // Save can't re-persist an unresolvable binding.
        demoteOrphanedTriggerParams()
        // Snapshot the loaded form as the dirty-check baseline (after demotion, so a
        // pure load reads as "no changes"). Captured from the SAME builder the check
        // uses, so an untouched form compares equal.
        loadedFormJSON = formSpecJSON()
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

    // Build the engine rule-spec from the current form state. The serialization
    // logic lives in RuleFormModel (unit-tested in RuleFormModelTests); this just
    // bundles the live @State and delegates, so the view owns no untestable logic.
    private func buildSpec() -> [String: Any]? { formModel.buildSpec() }

    // Snapshot the form's @State into the plain, testable model.
    private var formModel: RuleFormModel {
        var m = RuleFormModel()
        m.name = name; m.triggerType = triggerType; m.transition = transition
        m.stateValue = stateValue; m.stateValueBundleId = stateValueBundleId
        m.eventName = eventName; m.scheduleMode = scheduleMode
        m.everyMin = everyMin; m.atTime = atTime
        m.effectId = effectId
        m.notifyTitle = notifyTitle; m.notifyText = notifyText; m.notifyChannel = notifyChannel
        m.placements = placements; m.chainSteps = chainSteps
        m.shortcutName = shortcutName; m.openURLValue = openURLValue; m.speakText = speakText
        m.wallpaperImage = wallpaperImage; m.solidColor = solidColor; m.solidDisplay = solidDisplay
        m.minimizeAppName = minimizeAppName; m.minimizeAppBundleId = minimizeAppBundleId
        m.moveApp = moveApp; m.moveAppBundleId = moveAppBundleId; m.moveDisplay = moveDisplay
        m.launchAppName = launchAppName; m.launchAppBundleId = launchAppBundleId
        m.appearanceMode = appearanceMode; m.volumeOp = volumeOp; m.mediaKeyName = mediaKeyName
        m.opts = opts
        return m
    }
}

/// The app-target chooser shared by the minimize/hide/quit + move-to-display
/// effects (and the frontmost-app trigger value). Empty search shows the RUNNING
/// apps as quick options (the common target); typing searches ALL installed apps
/// (Spotlight via AppCatalog -- so a rule can target an app that isn't running
/// yet), storing the app's BUNDLE ID as the canonical match key and its display
/// name for the readable rule sentence. Also offers "the app from the trigger"
/// (the sentinel) when the trigger publishes one, and a free-text fallback for an
/// app Spotlight can't see -- that path stores a name only (engine matches by name).
private struct AppTargetChooser: View {
    @Binding var name: String        // display name | sentinel | "" (matches the TokenPill text)
    @Binding var bundleId: String    // canonical id; "" for the sentinel or a manual name
    let sentinel: String             // "@trigger:app"
    let triggerProvidesApp: Bool     // show the "from the trigger" row
    let fromTriggerLabel: String
    let warning: String?             // shown in place of the hint when non-nil
    let hint: String

    @State private var installed: [(name: String, bundleId: String)] = []
    @State private var running: [(name: String, bundleId: String)] = []
    @State private var query = ""
    @State private var loaded = false   // installed list finished gathering

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmed.isEmpty }
    // Empty search -> running apps (quick); typing -> all installed, filtered.
    private var rows: [(name: String, bundleId: String)] {
        searching ? installed.filter { $0.name.localizedCaseInsensitiveContains(trimmed) } : running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if triggerProvidesApp {
                row(label: fromTriggerLabel, selected: name == sentinel) {
                    name = sentinel; bundleId = ""
                }
                Divider()
            }
            TextField(Strings.t("rules.searchApps", default: "Search apps"), text: $query)
                .textFieldStyle(.roundedBorder)

            if searching && !loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(Strings.t("rules.loadingApps", default: "Finding apps…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if rows.isEmpty {
                // Searching with no match -> let the typed text stand as a literal name
                // (a not-yet-installed app / Spotlight off). Empty with nothing running
                // -> nudge to search.
                if searching {
                    Button { name = trimmed; bundleId = "" } label: {
                        Text(String(format: Strings.t("rules.useTypedApp", default: "Use \u{201C}%@\u{201D} as a name"), trimmed))
                            .font(.caption)
                    }.buttonStyle(.plain)
                } else {
                    Text(Strings.t("rules.typeToSearchApps", default: "Type to search all installed apps."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if !searching {
                    Text(Strings.t("rules.runningAppsHeader", default: "Running -- type to search all installed"))
                        .font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                }
                ScrollView {
                    // Lazy so a long installed-search list only resolves icons for the
                    // rows actually on screen.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.bundleId) { app in
                            appRow(app, selected: bundleId == app.bundleId) {
                                name = app.name; bundleId = app.bundleId; query = ""
                            }
                        }
                    }
                }
                // A ScrollView in a popover has NO intrinsic height -- with only a
                // maxHeight it collapses to zero and the rows vanish (the bug that hid
                // the running apps). Pin a definite height: fit the content, capped so
                // a long installed-search list scrolls.
                .frame(height: min(CGFloat(rows.count) * 28 + 4, 240))
            }

            Text(warning ?? hint)
                .font(.caption)
                .foregroundStyle(warning != nil ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            running = AppCatalog.runningApps()       // instant -- the quick options
            installed = await AppCatalog.installedApps()
            loaded = true
        }
    }

    // A selectable row: a leading check when chosen, the label, full-width hit area.
    // Used for the non-app "from the trigger" option.
    @ViewBuilder private func row(label: String, selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                Text(label).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    // An app row: the app's icon, its name, and a trailing check when chosen.
    @ViewBuilder private func appRow(_ app: (name: String, bundleId: String),
                                     selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 8) {
                if let icon = AppCatalog.icon(forBundleId: app.bundleId) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app").frame(width: 16, height: 16).foregroundStyle(.secondary)
                }
                Text(app.name).foregroundStyle(.primary)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}
