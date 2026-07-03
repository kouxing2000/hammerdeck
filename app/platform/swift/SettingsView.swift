import SwiftUI
import AppKit

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

    /// Sentinel selection id for the host-level "General" pane (app preferences
    /// that are not a Lua feature -- Caps->Hyper, Show in Dock).
    static let generalId = "__general__"

    var body: some View {
        HSplitView {
            List(selection: $store.selectedFeatureId) {
                // Host-level app preferences, pinned above the feature catalog so
                // they are discoverable (not buried in the menubar only).
                Section(Strings.t("settings.app", default: "App")) {
                    Label(Strings.t("settings.general", default: "General"), systemImage: "gearshape")
                        .tag(Self.generalId)
                }
                ForEach(groupedCategories, id: \.self) { category in
                    Section(categoryLabel(category)) {
                        // Global behavior preferences live in General > Behavior,
                        // not the catalog -- filter them out here. Exception: a FAILED
                        // preference stays so its red "failed to load" row still shows
                        // (the Behavior section renders only healthy ones).
                        ForEach(store.features.filter { $0.category == category && (!$0.preference || $0.failed) }) { feature in
                            FeatureRow(store: store, feature: feature)
                                .tag(feature.id)
                        }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            Group {
                if store.selectedFeatureId == Self.generalId {
                    GeneralSettingsDetail(store: store)
                } else if let id = store.selectedFeatureId,
                   let feature = store.features.first(where: { $0.id == id }) {
                    FeatureDetail(store: store, feature: feature)
                } else {
                    Text(Strings.t("settings.select_feature", default: "Select a feature"))
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
        // Skip healthy preference features (they render in General, not the catalog)
        // so a category holding only preferences never shows as an empty section; a
        // FAILED preference stays, since its red row belongs in the catalog.
        for f in store.features where (!f.preference || f.failed) && !seen.contains(f.category) {
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
                    } else {
                        Image(systemName: featureIcon(feature))
                            .foregroundStyle(categoryColor(feature.category))
                            .font(.caption)
                            .frame(width: 16, alignment: .center)
                    }
                    Text(feature.name)
                }
                Text(feature.failed ? Strings.t("settings.failed_to_load", default: "Failed to load") : feature.triggerDesc)
                    .font(.caption)
                    .foregroundStyle(feature.failed ? .red : .secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { feature.enabled },
                set: { store.requestSetEnabled(feature.id, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(feature.kind == "failed")   // a never-registered module can't be toggled
        }
        .padding(.vertical, 2)
    }
}

/// Host-level app preferences (not Lua features): the Caps->Hyper toggle and
/// the Dock visibility toggle. Both mirror the menubar items and read/write the
/// same `Hammerdeck` defaults keys, so a change here or there stays in sync on
/// the next render. @State seeds from the live prefs on appear.
private struct GeneralSettingsDetail: View {
    @ObservedObject var store: SettingsStore
    @State private var capsHyper = CapsHyperPreference.enabled
    @State private var showInDock = DockPreference.showInDock
    @State private var language = LocalePreference.override
    @State private var showRestartPrompt = false

    // Global behavior toggles (feature.json "preference": true) surfaced here
    // instead of the feature catalog. Data-driven: any preference-flagged feature
    // appears automatically, no per-feature Swift.
    private var behaviorPreferences: [FeatureInfo] {
        store.features.filter { $0.preference && !$0.failed }
    }

    var body: some View {
        Form {
            Section(Strings.t("settings.keyboard", default: "Keyboard")) {
                Toggle(Strings.t("settings.caps_hyper_toggle", default: "Caps Lock acts as Hyper (⌘⌥⌃)"), isOn: $capsHyper)
                    .onChange(of: capsHyper) { on in CapsHyperPreference.userToggle(to: on) }
                Text(Strings.t("settings.caps_hyper_caption", default: "Hold Caps Lock as the ⌘⌥⌃ Hyper modifier so Hyper shortcuts are a one-key press. Double-tap Caps Lock for its normal lock. Remaps Caps Lock and needs Accessibility."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !behaviorPreferences.isEmpty {
                Section(Strings.t("settings.behavior", default: "Behavior")) {
                    ForEach(behaviorPreferences) { pref in
                        Toggle(pref.name, isOn: Binding(
                            get: { pref.enabled },
                            set: { store.requestSetEnabled(pref.id, $0) }
                        ))
                        Text(pref.description)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section(Strings.t("settings.app", default: "App")) {
                Toggle(Strings.t("settings.show_in_dock", default: "Show in Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { on in DockPreference.set(on); DockPreference.apply() }
                Text(String(format: Strings.t("settings.dock_caption", default: "Keep a %@ icon in the Dock (and a Cmd-Tab entry); click it to open Home. Off = a pure menubar app."), AppInfo.displayName))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(Strings.t("settings.language", default: "Language")) {
                Picker(Strings.t("settings.language", default: "Language"), selection: $language) {
                    ForEach(LocalePreference.options(), id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .onChange(of: language) { code in
                    // Only prompt on a real change (onAppear re-seeds the same value).
                    guard code != LocalePreference.override else { return }
                    LocalePreference.set(code)
                    showRestartPrompt = true
                }
                Text(String(format: Strings.t("settings.language_caption", default: "Pick the app language, or follow the macOS system language. Relaunch %@ to fully apply a change."), AppInfo.displayName))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.t("settings.general", default: "General"))
        // A language change only fully applies on a fresh boot, so offer to
        // restart now (or later -- the preference is already saved).
        .alert(Strings.t("settings.lang_restart_title", default: "Language changed"),
               isPresented: $showRestartPrompt) {
            Button(Strings.t("settings.lang_restart_now", default: "Restart Now")) {
                AppRelaunch.restart()
            }
            Button(Strings.t("settings.lang_restart_later", default: "Later"), role: .cancel) {}
        } message: {
            Text(String(format: Strings.t("settings.lang_restart_msg",
                default: "Restart %@ now to apply the new language?"), AppInfo.displayName))
        }
        // Re-seed from the live prefs (e.g. if toggled from the menubar meanwhile).
        .onAppear {
            capsHyper = CapsHyperPreference.enabled
            showInDock = DockPreference.showInDock
            language = LocalePreference.override
        }
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
                        feature.errorMessage.isEmpty ? Strings.t("settings.feature_failed_to_start", default: "This feature failed to start.") : feature.errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            Section {
                Text(feature.description)
                    .foregroundStyle(.secondary)
                LabeledContent(Strings.t("settings.trigger", default: "Trigger"), value: feature.triggerDesc)
                LabeledContent(Strings.t("settings.kind", default: "Kind"), value: feature.kind == "service" ? Strings.t("settings.always_on_service", default: "Always-on service") : Strings.t("settings.triggered_action", default: "Triggered action"))
                if !feature.version.isEmpty {
                    LabeledContent(Strings.t("settings.version", default: "Version"), value: feature.version)
                }
            }
            // One trigger editor per declared action (a plugin may have several
            // shortcuts). Pure services have none.
            ForEach(feature.actions) { action in
                Section(feature.actions.count == 1
                        ? Strings.t("settings.bind_trigger", default: "Bind trigger")
                        : String(format: Strings.t("settings.trigger_named", default: "Trigger -- %@"), action.label)) {
                    TriggerEditor(store: store, feature: feature, action: action)
                        // Remount when the bound trigger changes so local edit
                        // state re-seeds from the new current spec.
                        .id("\(feature.id)|\(action.id)|\(action.triggerDesc)")
                }
            }
            // Options grouped into sections: each option's `section` (or the
            // default "Options") becomes a Section header, in declaration order.
            ForEach(optionSections, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.opts) { opt in
                        OptionEditor(store: store, featureId: feature.id, opt: opt)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.name)
    }

    /// Options bucketed by their `section` field, preserving first-appearance
    /// order; an option without a section falls under "Options".
    private var optionSections: [(name: String, opts: [OptionInfo])] {
        var order: [String] = []
        var groups: [String: [OptionInfo]] = [:]
        for opt in feature.options {
            let s = opt.section.isEmpty ? Strings.t("settings.options", default: "Options") : opt.section
            if groups[s] == nil { order.append(s) }
            groups[s, default: []].append(opt)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

// MARK: - Per-type option editors (the form generator)

private struct OptionEditor: View {
    @ObservedObject var store: SettingsStore
    let featureId: String
    let opt: OptionInfo

    // collapsible options start closed; the disclosure header shows the label
    // (and a "customized" tag when overridden) so the form stays scannable.
    @State private var expanded = false

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { store.optionValue(featureId, opt) as? Bool ?? false },
            set: { store.setOptionValue(featureId, opt, $0) }
        )
    }

    var body: some View {
        Group {
            if opt.collapsible {
                collapsibleBody
            } else {
                standardBody
            }
        }
        // gatedBy: stay grayed until the secret this option depends on validates.
        .disabled(gateClosed)
        // NB: do NOT key this view on store.optionEpoch -- the editors read
        // live through their bindings and re-render on @Published changes, so a
        // remount is unneeded AND it steals focus from a TextField/TextEditor on
        // every keystroke (the value write bumps optionEpoch). Stable identity
        // (ForEach keys by opt.key) keeps focus while typing.
    }

    /// The default layout: control on top, then reset/hint/action below.
    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                editor
                // siteList manages its own rows (add/remove); a blanket reset
                // would be confusing, so it has no reset affordance.
                if store.isOptionOverridden(featureId, opt) && opt.type != "siteList" { resetButton }
            }
            hintView
            actionButton
        }
    }

    /// A collapsible option: just a label + triangle until expanded, then the
    /// full editor (hint, reset, action) inside. Keeps a tall control (e.g. a
    /// multiline prompt) out of the way until the user wants to edit it.
    private var collapsibleBody: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                editor
                hintView
                actionButton
                if store.isOptionOverridden(featureId, opt) {
                    Button {
                        store.resetOption(featureId, opt)
                    } label: {
                        Label(Strings.t("settings.reset_to_default", default: "Reset to default"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 6) {
                Text(opt.label)
                // A subtle "customized" tag flags an edited prompt without
                // forcing the user to expand each one to check.
                if store.isOptionOverridden(featureId, opt) {
                    Text(Strings.t("settings.customized", default: "customized"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resetButton: some View {
        Button {
            store.resetOption(featureId, opt)
        } label: {
            Image(systemName: "arrow.uturn.backward.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Strings.t("settings.reset_to_default", default: "Reset to default"))
    }

    /// Optional one-line caption explaining the option / its requirement.
    @ViewBuilder
    private var hintView: some View {
        if !opt.hint.isEmpty {
            Text(opt.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Optional action button (e.g. "Test") -- runs the feature's optionAction.
    /// Enabled only once the feature is on and a value is set.
    @ViewBuilder
    private var actionButton: some View {
        if !opt.actionLabel.isEmpty {
            Button(opt.actionLabel) { store.runOptionAction(featureId, opt) }
                .controlSize(.small)
                .disabled(!featureEnabled || optionValueIsEmpty)
        }
    }

    /// A bool action with an animated preview CARD (the per-action analog of a
    /// feature's gallery card): the animation on top, the label + switch below.
    private var boolPreviewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Auto-plays (not hover-gated) so the animation is visible at a
            // glance -- there are only a handful of these per feature, unlike
            // the gallery's many cards.
            OptionPreviewScene(token: opt.preview, playing: true)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.15), lineWidth: 1))
            HStack {
                Text(opt.label)
                Spacer()
                Toggle("", isOn: boolBinding).labelsHidden()
            }
        }
    }

    /// A validate-able secret: the field plus a Validate button that checks the
    /// credential and unlocks the gatedBy options below it.
    private var validatableSecretField: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(opt.label) {
                SecureField("", text: secretBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.trailing)
            }
            HStack(spacing: 8) {
                Button(Strings.t("settings.validate", default: "Validate")) { store.validate(featureId, opt) }
                    .disabled(secretBinding.wrappedValue.isEmpty || isValidating)
                validationStatus
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch opt.type {
        case "bool" where !opt.preview.isEmpty:
            boolPreviewCard
        case "bool":
            Toggle(opt.label, isOn: boolBinding)
        case "int":
            Stepper(value: intBinding, in: intRange) {
                LabeledContent(opt.label, value: "\(intBinding.wrappedValue)")
            }
        case "enum":
            Picker(opt.label, selection: stringBinding) {
                ForEach(enumValues, id: \.self) { Text(opt.enumLabel($0)).tag($0) }
            }
        case "time":
            LabeledContent(opt.label) {
                TextField("HH:MM", text: timeBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        case "string" where opt.multiline:
            VStack(alignment: .leading, spacing: 4) {
                // When collapsible, the disclosure header already shows the label.
                if !opt.collapsible { Text(opt.label) }
                TextEditor(text: stringBinding)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
        case "string":
            LabeledContent(opt.label) {
                TextField("", text: stringBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.trailing)
            }
        case "secret" where opt.validate != nil:
            validatableSecretField
        case "secret":
            LabeledContent(opt.label) {
                SecureField("", text: secretBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.trailing)
            }
        case "appList":
            // Pick from the currently-running apps; we store the chosen app's
            // BUNDLE ID (stable across languages, and what launch_or_focus_app
            // needs to relaunch it later). The label resolves that id back to the
            // app's display name. Empty = the feature's default (e.g. macOS
            // Dictionary).
            LabeledContent(opt.label) {
                Menu {
                    Button(appListDefaultLabel) { store.setOptionValue(featureId, opt, "") }
                    Divider()
                    ForEach(AppCatalog.runningApps(), id: \.bundleId) { app in
                        Button(app.name) { store.setOptionValue(featureId, opt, app.bundleId) }
                    }
                } label: {
                    Text(appListSelectionLabel).lineLimit(1)
                }
                .frame(maxWidth: 240)
            }
        case "siteList":
            VStack(alignment: .leading, spacing: 4) {
                if !opt.collapsible { Text(opt.label) }
                SiteListEditor(
                    json: store.optionValue(featureId, opt) as? String
                        ?? (opt.defaultValue as? String ?? ""),
                    onChange: { store.setOptionValue(featureId, opt, $0) }
                )
            }
        default:
            LabeledContent(opt.label, value: String(format: Strings.t("settings.editor_not_built", default: "(%@ editor not built yet)"), opt.type))
                .foregroundStyle(.secondary)
        }
    }

    /// gatedBy: this option is grayed until the secret it names has validated.
    private var gateClosed: Bool {
        guard let g = opt.gatedBy else { return false }
        return !store.isValidated(featureId, g)
    }

    /// The choices for an enum: the list fetched by the secret named in
    /// `valuesFrom` (after a successful Validate), else the manifest seed. The
    /// current selection is always included so the Picker never shows blank.
    private var enumValues: [String] {
        guard let from = opt.valuesFrom else { return opt.values }
        let fetched = store.fetchedChoices(featureId, from)
        var vals = fetched.isEmpty ? opt.values : fetched
        let current = stringBinding.wrappedValue
        if !current.isEmpty && !vals.contains(current) { vals.insert(current, at: 0) }
        return vals
    }

    /// Whether the secret is mid-validation (Validate button stays disabled).
    private var isValidating: Bool {
        if case .validating = store.validationState(featureId, opt.key) { return true }
        return false
    }

    /// The result chip shown next to the Validate button.
    @ViewBuilder
    private var validationStatus: some View {
        switch store.validationState(featureId, opt.key) {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(Strings.t("settings.validating", default: "Validating...")).font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// Whether this option's feature is currently enabled (an optionAction needs
    /// the feature's bound ctx, so its button is dead until then).
    private var featureEnabled: Bool {
        store.features.first { $0.id == featureId }?.enabled ?? false
    }

    /// Whether the option's stored value is empty -- used to keep an action
    /// button (e.g. dict "Test") off until the user has actually chosen something.
    private var optionValueIsEmpty: Bool {
        (store.optionValue(featureId, opt) as? String ?? "").isEmpty
    }

    /// The menu entry for the empty/"use the default" choice -- named by the
    /// option (e.g. "macOS Dictionary (default)"), or a generic fallback.
    private var appListDefaultLabel: String {
        opt.defaultLabel.isEmpty ? Strings.t("settings.default_app", default: "Default app") : String(format: Strings.t("settings.default_with_label", default: "%@ (default)"), opt.defaultLabel)
    }

    /// What the appList menu shows as selected: the default-app label when empty,
    /// else the display name resolved from the stored bundle id (falling back to
    /// the raw id if the app can't be resolved -- e.g. uninstalled).
    private var appListSelectionLabel: String {
        let v = stringBinding.wrappedValue
        if v.isEmpty { return appListDefaultLabel }
        return AppCatalog.displayName(forBundleId: v) ?? v
    }

    /// Keychain-backed string. Never seeded from a manifest default -- get
    /// returns the stored secret or empty; set persists (empty clears it).
    private var secretBinding: Binding<String> {
        Binding(
            get: { store.optionValue(featureId, opt) as? String ?? "" },
            set: { store.setOptionValue(featureId, opt, $0) }
        )
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
                if HHMM.isValid(newValue) {
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
        case .hotkey:        return Strings.t("settings.mode_hotkey", default: "Hotkey")
        case .chord:         return Strings.t("settings.mode_chord", default: "Chord")
        case .scheduleEvery: return Strings.t("settings.mode_every", default: "Every N minutes")
        case .scheduleAt:    return Strings.t("settings.daily_at", default: "Daily at")
        case .event:         return Strings.t("settings.mode_event", default: "System event")
        }
    }

    // AUTOMATED modes fire with no human present and no live UI context, so they
    // only make sense for actions an author marked `automatable`. The manual
    // modes (hotkey/chord) suit any action.
    var isAutomated: Bool {
        switch self {
        case .hotkey, .chord:                       return false
        case .scheduleEvery, .scheduleAt, .event:   return true
        }
    }

    // The trigger types offered for an action: manual always, automated only
    // when the action opts in.
    static func available(automatable: Bool) -> [TriggerMode] {
        automatable ? allCases : allCases.filter { !$0.isAutomated }
    }
}

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

        // What this action does -- the per-action analog of the feature's
        // description (rendered only when the action declares one).
        if !action.description.isEmpty {
            Text(action.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // "Why this key" hint for the DEFAULT binding (e.g. "P for Password").
        // Hidden once the user rebinds away from the default -- it describes the
        // default's choice and would otherwise mislead.
        if !action.mnemonic.isEmpty && !action.triggerOverridden {
            Label(action.mnemonic, systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        let modes = TriggerMode.available(automatable: action.automatable)
        if modes.count > 1 {
            Picker(Strings.t("settings.type", default: "Type"), selection: $mode) {
                ForEach(modes) { Text($0.label).tag($0) }
            }
        }

        switch mode {
        case .hotkey:
            LabeledContent(Strings.t("settings.shortcut", default: "Shortcut")) {
                ShortcutRecorder(mods: $mods, key: $key)
            }
        case .chord:
            // Prefix + follow keys on ONE row: record the prefix, then the
            // "then" field for the ordered follow keys (mirrors the Shortcut Map
            // grid, where a chord also lives in a single row).
            LabeledContent(Strings.t("settings.shortcut", default: "Shortcut")) {
                // Two visual units -- the recorded prefix and the typed follow
                // keys -- with a wider gap around the "then" connector than the
                // recorder's internal spacing, so they read as distinct groups.
                // The follows field is bordered (a "type here" box) to set it
                // apart from the prefix's glyph display, mirroring the grid.
                HStack(spacing: 12) {
                    ShortcutRecorder(mods: $mods, key: $key, placeholder: "Record prefix")
                    Text(Strings.t("settings.then", default: "then"))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    // labelsHidden + prompt: the title would otherwise render as
                    // a persistent label beside the box on macOS (the stray
                    // "keys" that wrapped); we want a placeholder-only field.
                    TextField(Strings.t("settings.follow_keys", default: "Follow keys"), text: $follows, prompt: Text("b c"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                }
            }
            Text(Strings.t("settings.chord_caption", default: "Record the prefix, then type the follow keys in order (e.g. ⌘⇧A then B)."))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .scheduleEvery:
            Stepper(value: $everyMin, in: 1...1440) {
                LabeledContent(Strings.t("settings.interval", default: "Interval"), value: String(format: Strings.t("settings.interval_value", default: "%d min"), everyMin))
            }
        case .scheduleAt:
            LabeledContent(Strings.t("settings.daily_at", default: "Daily at")) {
                TextField("HH:MM", text: $at)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
        case .event:
            Picker(Strings.t("settings.event", default: "Event"), selection: $event) {
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
            Button(Strings.t("settings.apply", default: "Apply")) { conflict = store.setTrigger(feature.id, action.id, buildSpec()) }
                .disabled(applyDisabled || !dirty || conflict != nil)
            // Once the edit differs from what's applied, let the user back out
            // in place (discard the unapplied change) without navigating away.
            if dirty {
                Button(Strings.t("settings.revert", default: "Revert")) { revertEdit() }
                    .help(Strings.t("settings.revert_help", default: "Discard the unapplied change and restore the current shortcut"))
            }
            if action.triggerOverridden {
                Button(Strings.t("settings.reset_to_default", default: "Reset to default")) {
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
        case .scheduleAt: return !HHMM.isValid(at)
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
    private var followKeys: [String] { TriggerSpec.parseFollows(follows) }

    private func buildSpec() -> TriggerSpec {
        switch mode {
        // hotkey + chord share TriggerSpec.keyish with the Shortcut Map, so the
        // canonical mod order + key casing can't drift between the two surfaces.
        case .hotkey:
            return TriggerSpec.keyish(mods: mods, key: key, follows: "")
        case .chord:
            return TriggerSpec.keyish(mods: mods, key: key, follows: follows)
        case .scheduleEvery:
            return TriggerSpec(type: "schedule", everyMin: everyMin)
        case .scheduleAt:
            return TriggerSpec(type: "schedule", at: at)
        case .event:
            return TriggerSpec(type: "event", event: event)
        }
    }
}
