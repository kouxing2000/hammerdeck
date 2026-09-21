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

    /// The live filter text. Local UI state -- resets when Settings reopens.
    @State private var query = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                searchField
                List(selection: $store.selectedFeatureId) {
                    // Host-level app preferences, pinned above the feature catalog so
                    // they are discoverable (not buried in the menubar only). Hidden
                    // when a search is active that it doesn't match.
                    if showGeneralRow {
                        Section(Strings.t("settings.app", default: "App")) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(Strings.t("settings.general", default: "General"), systemImage: "gearshape")
                                // When the query matched a BEHAVIOR PREFERENCE rather than
                                // the word "General", say so and name it -- otherwise the
                                // row looks like an unrelated leftover and the user
                                // concludes the feature they searched for is missing.
                                if let hit = matchedPreferenceNames, !hit.isEmpty {
                                    Text(String(format: Strings.t("settings.general.hit",
                                                                  default: "Behavior: %@"), hit))
                                        .font(.caption).foregroundStyle(.secondary)
                                        // A one-character query matches all three
                                        // preferences at once; their joined names
                                        // wrap to four lines in a 220pt sidebar.
                                        .lineLimit(1).truncationMode(.tail)
                                }
                            }
                            .tag(Self.generalId)
                        }
                    }
                    ForEach(groupedCategories, id: \.self) { category in
                        Section(categoryLabel(category)) {
                            // Global behavior preferences live in General > Behavior,
                            // not the catalog -- filter them out here. Exception: a FAILED
                            // preference stays so its red "failed to load" row still shows
                            // (the Behavior section renders only healthy ones).
                            ForEach(featuresIn(category)) { feature in
                                FeatureRow(store: store, feature: feature)
                                    .tag(feature.id)
                            }
                        }
                    }
                    if isSearching && showGeneralRow == false && groupedCategories.isEmpty {
                        Text(Strings.t("settings.no_matches", default: "No matching features"))
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            Group {
                if store.selectedFeatureId == Self.generalId {
                    GeneralSettingsDetail(store: store, searchQuery: query)
                } else if let id = store.selectedFeatureId,
                   let feature = store.features.first(where: { $0.id == id }) {
                    // Keyed on the id so the detail's own @State (which section is
                    // open) belongs to the feature being shown -- without it SwiftUI
                    // reuses one instance across sidebar selections and the disclosure
                    // state of the last feature carries onto the next.
                    FeatureDetail(store: store, feature: feature)
                        .id(feature.id)
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

    /// The filter field pinned above the sidebar list. A plain field (not
    /// `.searchable`, which needs a NavigationStack this HSplitView deliberately
    /// avoids) with a clear button.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.caption)
            TextField(Strings.t("settings.filter", default: "Filter features"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .accessibilityLabel(Strings.t("settings.filter_clear", default: "Clear filter"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .padding(8)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// A feature matches the filter by name, description, category label, OR any of
    /// its action labels -- so searching "left" finds Window Snap via its "Left
    /// half" action, not only by the feature's own name (findability is the point).
    private func matches(_ f: FeatureInfo) -> Bool {
        if !isSearching { return true }
        let q = trimmedQuery
        if f.name.localizedCaseInsensitiveContains(q) { return true }
        if f.description.localizedCaseInsensitiveContains(q) { return true }
        if categoryLabel(f.category).localizedCaseInsensitiveContains(q) { return true }
        return f.actions.contains { $0.label.localizedCaseInsensitiveContains(q) }
    }

    /// The catalog features in a category that pass the filter (healthy preferences
    /// still hidden -- they live in General; a FAILED preference stays for its red row).
    ///
    /// Ordered by the manifest's optional `order`, then by name. Unranked features
    /// (`order` nil, the common case) sort after every ranked one. Without this the
    /// rows arrived in catalog scan order -- the alphabetical directory walk -- which
    /// led the Windows section with the pointer-follow comfort setting and buried
    /// Window Snap, the one-key workhorse, at the bottom. The README generator sorts
    /// by the same two keys, so the two surfaces cannot disagree.
    private func featuresIn(_ category: String) -> [FeatureInfo] {
        store.features
            .filter { $0.category == category && (!$0.preference || $0.failed) && matches($0) }
            .sorted { ($0.order ?? Int.max, $0.name) < ($1.order ?? Int.max, $1.name) }
    }

    /// The healthy BEHAVIOR PREFERENCES matching the query, comma-joined, or nil
    /// when not searching / nothing matched.
    ///
    /// These features are deliberately kept out of the catalog list (they live in
    /// General > Behavior), but until this existed the search did not reach them
    /// EITHER -- so searching "pointer follows" answered "No matching features"
    /// for a feature the README documents by name under Windows. Two surfaces
    /// disagreeing about whether a thing exists is worse than either arrangement
    /// on its own; the fix is to let the search find them where they actually
    /// live, not to move them back into the catalog.
    private var matchedPreferenceNames: String? {
        guard isSearching else { return nil }
        let hits = store.features
            .filter { $0.preference && !$0.failed && matches($0) }
            .map(\.name)
        return hits.isEmpty ? nil : hits.joined(separator: ", ")
    }

    /// Show the host "General" row unless a search is active that it doesn't match
    /// -- by its own name, by any behavior preference it contains, or by the
    /// theme picker (searching "dark" is how a user looks for that setting, and
    /// the word appears nowhere else in the sidebar).
    private var showGeneralRow: Bool {
        if !isSearching { return true }
        let q = trimmedQuery
        return Strings.t("settings.general", default: "General").localizedCaseInsensitiveContains(q)
            || Strings.t("settings.app", default: "App").localizedCaseInsensitiveContains(q)
            || Strings.t("settings.appearance", default: "Appearance").localizedCaseInsensitiveContains(q)
            // Never spell these two out here: the pane opens a collapsed section
            // on the same predicate, and a second copy could drift into hiding
            // the row that section lives on.
            || DeveloperSectionDisclosure.matchesASection(query: q)
            || AppearancePreference.modes.contains {
                AppearancePreference.label(for: $0).localizedCaseInsensitiveContains(q)
            }
            || matchedPreferenceNames != nil
    }

    private var groupedCategories: [String] {
        var seen: [String] = []
        // Skip healthy preference features (they render in General, not the catalog)
        // so a category holding only preferences never shows as an empty section; a
        // FAILED preference stays, since its red row belongs in the catalog. Also
        // drop categories with no filter match, so no empty section renders.
        for f in store.features where (!f.preference || f.failed) && matches(f) && !seen.contains(f.category) {
            seen.append(f.category)
        }
        // Sort into the CANONICAL order rather than leaving it to catalog scan
        // order, which is really the alphabetical directory walk and puts the
        // sections wherever their first member happens to sort. Ties (an unranked
        // category, e.g. the synthesized "failed" one) fall back to their label so
        // the order is still stable rather than scan-dependent.
        //
        // CATEGORY_ORDER is the ONLY input -- see its own header for why the rank
        // is declared there rather than derived from `recommended` here.
        return seen.sorted { (categoryRank($0), categoryLabel($0))
                           < (categoryRank($1), categoryLabel($1)) }
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

private let kExtensionsAnchor = "general-extensions"
private let kMcpAnchor = "general-agent-access"

/// Whether each collapsed developer section should show itself, absent a manual
/// toggle by the user.
///
/// A pure function rather than a method on the view, because the search half is
/// the part that can silently regress and the view is not reachable from a test.
/// The failure it guards is specific: Settings search matches these two sections
/// by name, but that match only decides whether the General ROW appears in the
/// sidebar (SettingsView.showGeneralRow) -- it never filters or scrolls this
/// pane. So a query that matched a collapsed section must open it, or searching
/// "MCP" lands the user on a pane showing no trace of what they searched for,
/// which is worse than never having collapsed it.
///
/// The result is DERIVED, never latched: clearing the search field closes again
/// what the search opened. A latch that only ever set true was tried and is the
/// reason this is written down -- `Agent Access (MCP)` contains "a", so typing
/// the first letter of "appearance" pinned the whole MCP block open for the rest
/// of the visit.
enum DeveloperSectionDisclosure {
    /// A single character is not a search: every title here contains a common
    /// letter, so a one-character query matches something almost always and the
    /// pane would flash open on the way to any real query.
    static let minimumQueryLength = 2

    /// The collapsible sections, in pane order. Adding a third means adding it
    /// here and nowhere else -- which is the whole reason this list exists
    /// rather than two title comparisons written out at each call site.
    static var titles: [String] {
        [Strings.t("settings.extensions", default: "Extensions"),
         Strings.t("settings.mcp", default: "Agent Access (MCP)")]
    }

    /// Does the query name a collapsible section? `showGeneralRow` reads THIS to
    /// decide whether the General row survives the sidebar filter, and the pane
    /// reads it to decide whether to open one. Sharing the predicate is what
    /// makes the bad state unreachable: a query could otherwise open a section
    /// on a row the sidebar had already filtered away, so the auto-open would
    /// fire on a pane nobody could reach.
    static func matchesASection(query: String) -> Bool {
        titles.contains { matched($0, query) }
    }

    private static func matched(_ title: String, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count >= minimumQueryLength && title.localizedCaseInsensitiveContains(q)
    }

    /// - Parameter query: the RAW search field text; trimming is this function's
    ///   job, so its callers cannot disagree about it.
    static func shouldOpen(query: String,
                           extensionsDirSet: Bool,
                           mcpEnabled: Bool) -> (extensions: Bool, mcp: Bool) {
        (extensions: extensionsDirSet || matched(titles[0], query),
         mcp: mcpEnabled || matched(titles[1], query))
    }
}

/// Host-level app preferences (not Lua features): the Caps->Hyper toggle and
/// the Dock visibility toggle. Both mirror the menubar items and read/write the
/// same `Hammerdeck` defaults keys, so a change here or there stays in sync on
/// the next render. @State seeds from the live prefs on appear.
private struct GeneralSettingsDetail: View {
    @ObservedObject var store: SettingsStore
    /// The live sidebar search text. The two developer sections below are
    /// collapsed by default, and search does NOT filter this pane -- it only
    /// decides whether the General row appears in the sidebar (see
    /// showGeneralRow). So a query that matched one of them by name must open
    /// it, or searching "MCP" lands the user on a pane where the match is
    /// invisible -- strictly worse than not collapsing at all.
    /// Raw, not trimmed: DeveloperSectionDisclosure owns that.
    let searchQuery: String
    @State private var capsHyper = CapsHyperPreference.enabled
    @State private var showInDock = DockPreference.showInDock
    // Seeded from launchd, which owns this one -- see LoginItem. Approval-pending
    // seeds the switch ON: the user did ask, macOS is just holding it.
    @State private var openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
    @State private var loginItemError: String?
    @State private var appearance = AppearancePreference.mode
    // Seeded from Sparkle, which owns the persistence -- there is no
    // `hammerdeck.*` key for this, deliberately (two sources of truth drift).
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    // Read once into state so clearing the override re-renders the section.
    @State private var testFeedHost = Updater.shared.testFeedHost
    // Ours, not Sparkle's -- the delegate reads the same key on every check.
    @State private var receivesBeta = Updater.shared.receivesBeta
    @State private var language = LocalePreference.override
    @State private var showRestartPrompt = false
    @State private var extensionsDir = ExtensionsPreference.dir
    @State private var mcpEnabled = McpPreference.enabled
    @State private var mcpPortText = String(McpPreference.port)
    @ObservedObject private var mcp = McpServer.shared
    // nil = follow DeveloperSectionDisclosure; non-nil = the user worked the
    // disclosure triangle and their answer wins. Never persisted: "is this in
    // use" is inferred from the setting itself, so there is no advanced-mode
    // preference to find before you can find the thing it hides.
    @State private var extOverride: Bool?
    @State private var mcpOverride: Bool?

    // Global behavior toggles (feature.json "preference": true) surfaced here
    // instead of the feature catalog. Data-driven: any preference-flagged feature
    // appears automatically, no per-feature Swift.
    private var behaviorPreferences: [FeatureInfo] {
        store.features.filter { $0.preference && !$0.failed }
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                // Absent in a dev `swift run`: no packaged Info.plist means no
                // SUFeedURL, so there is no updater to configure. Same reasoning as
                // the menubar item -- show nothing rather than a dead control.
                if Updater.shared.isAvailable {
                    Toggle(Strings.t("settings.auto_update", default: "Check for updates automatically"), isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { on in Updater.shared.automaticallyChecks = on }
                    Text(String(format: Strings.t("settings.auto_update_caption", default: "Look for a new %@ in the background and offer it when one appears. Every update is signature-verified before it installs; you are always asked before anything is replaced."), AppInfo.displayName))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A channel within the same feed, which is why this is safe to
                    // ship as a switch while the test-feed redirect below is not:
                    // turning it on ADDS the candidates, and turning it off
                    // returns to exactly what everyone else is offered.
                    Toggle(Strings.t("settings.beta_channel", default: "Receive beta updates"), isOn: $receivesBeta)
                        .onChange(of: receivesBeta) { on in Updater.shared.receivesBeta = on }
                    Text(Strings.t("settings.beta_channel_caption", default: "Every release is offered here first, before it goes out to everyone. Betas are signed and verified exactly like a release, but they have had less use -- turn this off at any time to go back to the general releases."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Only ever visible on a copy someone pointed at another
                    // feed from a terminal. Nothing we ship does that, and this
                    // exists for the way BACK: the redirect survives updates,
                    // and such a machine behaves normally right up until it
                    // silently stops being offered real releases.
                    if let host = testFeedHost {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Strings.t("settings.test_feed", default: "Updates are coming from a test feed."))
                                .font(.callout.weight(.semibold))
                            Text(String(format: Strings.t("settings.test_feed_caption", default: "This copy checks %@ instead of the release feed, and will not be offered real releases until you switch back."), host))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(Strings.t("settings.test_feed_reset", default: "Use the release feed")) {
                                Updater.shared.usePackagedFeed()
                                testFeedHost = Updater.shared.testFeedHost
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(.secondary.opacity(0.45), lineWidth: 1))
                    }
                }
                // Absent in a dev `swift run` for the same reason the updater
                // rows above are: there is no bundle for launchd to register.
                if LoginItem.isAvailable {
                    Toggle(Strings.t("settings.login_item", default: "Open at login"), isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { on in
                            // The macOS state, not the switch's: approval-pending
                            // counts as "the user asked for it" even though it is
                            // not running yet.
                            let current = LoginItem.isEnabled || LoginItem.needsApproval
                            // Our own write-back below re-enters here; only a real
                            // user flip differs from what the OS already reports.
                            guard on != current else { return }
                            loginItemError = LoginItem.set(on)
                            openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
                        }
                    Text(String(format: Strings.t("settings.login_item_caption", default: "Start %@ when you log in. Its shortcuts, schedules and automation rules only run while it is open, so without this they stop at every restart -- with no menubar icon left to say so."), AppInfo.displayName))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let err = loginItemError {
                        Text(String(format: Strings.t("settings.login_item_failed", default: "Could not set this: %@"), err))
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if LoginItem.needsApproval {
                        // Registered, and macOS is waiting on the user. Saying
                        // nothing here would leave a switch that reads ON above an
                        // app that never starts.
                        Text(Strings.t("settings.login_item_approval", default: "macOS is holding this until you allow it in Login Items."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(Strings.t("settings.login_item_open_settings", default: "Open Login Items…")) {
                            LoginItem.openSystemSettings()
                        }
                    }
                }
                Toggle(Strings.t("settings.show_in_dock", default: "Show in Dock"), isOn: $showInDock)
                    .onChange(of: showInDock) { on in DockPreference.set(on); DockPreference.apply() }
                Text(String(format: Strings.t("settings.dock_caption", default: "Keep a %@ icon in the Dock (and a Cmd-Tab entry); click it to open Home. Off = a pure menubar app."), AppInfo.displayName))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(Strings.t("settings.appearance", default: "Appearance"), selection: $appearance) {
                    ForEach(AppearancePreference.modes, id: \.self) { mode in
                        Text(AppearancePreference.label(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { mode in
                    AppearancePreference.set(mode)
                    AppearancePreference.apply()
                }
                Text(String(format: Strings.t("settings.appearance_caption", default: "Theme for %@'s own windows and panels, or follow the macOS system setting. Overlays drawn on top of other apps -- the key legends, the window-mode cards -- stay dark either way."), AppInfo.displayName))
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
            // The two developer sections sit LAST, and collapsed. Hammerdeck's
            // promise is config-and-select ("lowers the bar from write Lua"),
            // and both of these are for people who write code -- so Language, a
            // mainstream setting, reads before them rather than after. Neither
            // is discovered by scrolling Settings anyway: an extension author
            // arrives from the README or the agent guide.
            //
            // Every row inside a DisclosureGroup states its own leading
            // alignment: a grouped Form centers a row it cannot size, and
            // DisclosureGroup content is not laid out as form rows. Same
            // workaround as capabilityRows below, and as AboutSection.
            Section {
                DisclosureGroup(isExpanded: extBinding) {
                    HStack {
                        Text(extensionsDir ?? Strings.t("settings.extensions_not_set", default: "Not set"))
                            .foregroundStyle(extensionsDir == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(Strings.t("settings.extensions_choose", default: "Choose...")) {
                            chooseExtensionsFolder()
                        }
                        if extensionsDir != nil {
                            Button(Strings.t("settings.extensions_clear", default: "Clear")) {
                                setExtensionsDir(nil)
                            }
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // What the last scan actually found. Picking a folder used to
                    // change this row's path text and nothing else, so an empty
                    // folder, a wrongly laid-out one, and one whose extensions
                    // were all rejected were the same pixels.
                    if let status = store.extensionsStatus {
                        Text(status)
                            .font(.caption)
                            // A flag, not a substring test on the message: the
                            // zh-Hans string contains no "failed" to match.
                            .foregroundStyle(store.extensionsHaveFailures ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(Strings.t("settings.extensions_caption", default: "Load your own Lua features from a folder. Each extension is a subfolder laid out like a built-in feature -- <id>/lua/init.lua, plus an optional feature.json. Applied immediately, and re-scanned on every Reload Features."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(Strings.t("settings.extensions", default: "Extensions"))
                }
            }
            .id(kExtensionsAnchor)
            Section {
                DisclosureGroup(isExpanded: mcpBinding) {
                    Toggle(Strings.t("settings.mcp_toggle", default: "Allow agent connections (MCP)"), isOn: $mcpEnabled)
                        .onChange(of: mcpEnabled) { on in
                            McpPreference.setEnabled(on)
                            if on { McpServer.shared.startFromPreferences() } else { McpServer.shared.stop() }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Live server state: the URL an agent talks to, or why the
                    // bind failed (the port-in-use case).
                    switch mcp.status {
                    case .running(let port):
                        Text(String(format: Strings.t("settings.mcp_running", default: "Serving at http://127.0.0.1:%d/mcp"), Int(port)))
                            .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .failed(let reason):
                        Text(String(format: Strings.t("settings.mcp_failed", default: "Failed to start: %@"), reason))
                            .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .off, .starting:
                        EmptyView()
                    }
                    HStack {
                        Text(Strings.t("settings.mcp_port", default: "Port"))
                        TextField("", text: $mcpPortText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { commitMcpPort() }
                            // A typed port only reaches McpPreference on submit, so
                            // walking away from the field used to discard it: leaving
                            // the Settings tab destroys GeneralSettingsDetail (the
                            // Homepage switches on nav.destination), and mcpPortText
                            // re-seeds from the stored port on the way back. The edit
                            // vanished with no sign it had been dropped.
                            .onDisappear { commitMcpPort() }
                        Spacer()
                        Button(Strings.t("settings.mcp_copy_command", default: "Copy Connect Command")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(McpPreference.connectCommand(), forType: .string)
                        }
                        // Only meaningful while something is actually listening:
                        // after a failed bind the command would name a dead port.
                        .disabled(!mcpRunning)
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Strings.t("settings.mcp_caption", default: "Let a coding agent (e.g. Claude Code) connect to the running app to author extensions -- inspect the catalog, reload after an edit, read load failures, and test-fire an action. Local connections only, guarded by a token the Copy Connect Command includes."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button(Strings.t("settings.mcp_copy_guide", default: "Copy Agent Guide")) {
                            if let text = try? McpServer.shared.guideText() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                        Button(Strings.t("settings.mcp_export_guide", default: "Export Guide...")) {
                            exportAgentGuide()
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Strings.t("settings.mcp_guide_caption", default: "The guide teaches an agent the extension contract. Export it as a Claude Code skill (save as .claude/skills/hammerdeck-extensions/SKILL.md) or paste it into any agent's context."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(Strings.t("settings.mcp", default: "Agent Access (MCP)"))
                }
            }
            .id(kMcpAnchor)
        }
        // Scroll on the STATE CHANGE, not from inside the toggle: a scrollTo
        // issued beside the expansion resolves against geometry the expanded
        // content is not in yet (same trap as the feature-detail About section).
        // Without this the search fix is invisible in exactly the case it was
        // written for -- these two sections are LAST in the pane, so a match
        // opens below the fold.
        .onChange(of: extIsOpen) { isOpen in
            guard isOpen else { return }
            withAnimation { proxy.scrollTo(kExtensionsAnchor, anchor: .bottom) }
        }
        .onChange(of: mcpIsOpen) { isOpen in
            guard isOpen else { return }
            withAnimation { proxy.scrollTo(kMcpAnchor, anchor: .bottom) }
        }
        .formStyle(.grouped)
        // (no .navigationTitle -- see the FeatureDetail note: it retitles the window)
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
            // System Settings can revoke this behind our back, so re-read launchd
            // every time the pane appears rather than trusting the last write.
            openAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
            loginItemError = nil
            receivesBeta = Updater.shared.receivesBeta
            appearance = AppearancePreference.mode
            language = LocalePreference.override
            extensionsDir = ExtensionsPreference.dir
            mcpEnabled = McpPreference.enabled
            mcpPortText = String(McpPreference.port)
        }
        }
    }

    /// What the two disclosure triangles read and write. The user's own toggle
    /// wins while it is set; everything else follows the derived answer, so
    /// clearing the search field closes again what the search opened.
    private var derived: (extensions: Bool, mcp: Bool) {
        DeveloperSectionDisclosure.shouldOpen(query: searchQuery,
                                              extensionsDirSet: extensionsDir != nil,
                                              mcpEnabled: mcpEnabled)
    }
    private var extIsOpen: Bool { extOverride ?? derived.extensions }
    private var mcpIsOpen: Bool { mcpOverride ?? derived.mcp }
    private var extBinding: Binding<Bool> {
        Binding(get: { extIsOpen }, set: { extOverride = $0 })
    }
    private var mcpBinding: Binding<Bool> {
        Binding(get: { mcpIsOpen }, set: { mcpOverride = $0 })
    }

    /// Pick the user-extensions folder (mirrors RulesView's wallpaper picker,
    /// but for a directory).
    private func chooseExtensionsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.t("settings.extensions_choose", default: "Choose...")
        if panel.runModal() == .OK, let url = panel.url {
            setExtensionsDir(url.path)
        }
    }

    /// Persist the folder (nil clears) and reload the Lua platform so the change
    /// applies right away -- registry.loadExtensions re-reads this key on reload.
    private func setExtensionsDir(_ dir: String?) {
        ExtensionsPreference.set(dir)
        extensionsDir = ExtensionsPreference.dir
        store.userReload()
    }

    /// Is the endpoint actually serving right now (vs merely switched on)?
    private var mcpRunning: Bool {
        if case .running = mcp.status { return true }
        return false
    }

    /// Commit the MCP port field: clamp to a real port, persist, restart the
    /// server if it is on so the new port takes effect immediately.
    private func commitMcpPort() {
        guard let port = UInt16(mcpPortText), port > 0 else {
            mcpPortText = String(McpPreference.port)   // reject junk, re-seed
            return
        }
        // Below 1024 needs root, so the bind is guaranteed to fail -- and this now
        // runs on the field going AWAY, where "27" is far more likely to be a
        // half-typed 27121 than a deliberate choice.
        guard port >= 1024 else {
            mcpPortText = String(McpPreference.port)
            return
        }
        // Unchanged is a no-op, not a restart -- this runs on every teardown, and
        // bouncing a healthy server for an unedited field is pure churn. Unless
        // it is NOT running: re-submitting the same port is the only retry after
        // a failed bind (the status row offers no button), so that path must
        // still reach startFromPreferences.
        guard port != McpPreference.port || !mcpRunning else { return }
        McpPreference.setPort(port)
        if mcpEnabled { McpServer.shared.startFromPreferences() }
    }

    /// Save the agent guide as a skill file (SKILL.md) wherever the user picks.
    private func exportAgentGuide() {
        guard let text = try? McpServer.shared.guideText() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.prompt = Strings.t("settings.mcp_export_prompt", default: "Export")
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Anchor id for the About section, so the header's "About" link can scroll to
/// what it just opened.
private let kAboutAnchor = "feature-detail-about"

/// The pane ranks by how often a thing is EDITED, not by how much it explains:
/// the generated options come first, the shortcut rows collapse to one line
/// each, and the prose + capability list live behind a closed disclosure. The
/// old order stacked three blocks of read-once material above the options,
/// which put the payload below the fold for every feature with a long
/// description or more than a couple of actions.
private struct FeatureDetail: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo

    @State private var aboutExpanded: Bool

    init(store: SettingsStore, feature: FeatureInfo) {
        self.store = store
        self.feature = feature
        // A pure service with no options has nothing else to show; opening
        // About makes the pane a page instead of a stack of closed doors. A
        // module that never LOADED also has no options and no actions, but its
        // emptiness means the opposite -- nothing about it was read -- so it is
        // excluded rather than led with a section it cannot honestly fill.
        _aboutExpanded = State(initialValue: feature.kind != "failed"
            && feature.options.isEmpty
            && Self.staticActions(of: feature).isEmpty)
    }

    /// The rebindable actions. DYNAMIC ones are omitted: they are created + bound
    /// by the option editor that owns them (window_snap's Saved-placements list
    /// binds each snap's shortcut inline), so a row here would duplicate them.
    ///
    /// Static so `init` can seed the disclosure state from the same definition
    /// the body renders from -- two hand-rolled copies of "which actions count"
    /// would drift the moment one changed.
    private static func staticActions(of feature: FeatureInfo) -> [ActionInfo] {
        feature.actions.filter { !$0.dynamic }
    }

    private var staticActions: [ActionInfo] { Self.staticActions(of: feature) }

    var body: some View {
        ScrollViewReader { proxy in
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
                    // The pane's own heading. The feature name used to reach the
                    // user only as the WINDOW title (via .navigationTitle) -- which
                    // was the bug: it retitled the whole window and stuck there.
                    // Naming the page in-content identifies it without touching the
                    // window, and keeps DebugShot captures (which render this form
                    // alone, no sidebar) self-identifying.
                    FeatureDetailHeader(store: store, feature: feature) {
                        withAnimation { aboutExpanded = true }
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
                Section(Strings.t("settings.shortcuts", default: "Shortcuts")) {
                    if staticActions.isEmpty {
                        // Nothing rebindable. Say what this feature IS driven by
                        // (the registry's own summary -- "always-on service", or a
                        // count when every action is dynamic) rather than showing
                        // an empty box.
                        Text(feature.triggerDesc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(staticActions) { action in
                            // A lone shortcut opens with the pane: collapsing ONE
                            // row buys no density, it just puts the editor, its
                            // preview and its mnemonic behind a click that has
                            // nothing to choose between.
                            TriggerRow(store: store, feature: feature, action: action,
                                       startsExpanded: staticActions.count == 1)
                        }
                    }
                }
                AboutSection(feature: feature, expanded: $aboutExpanded)
            }
            .formStyle(.grouped)
            // Scroll on the STATE CHANGE, not from inside the click handler: a
            // scrollTo issued beside the expansion resolves against geometry the
            // expanded content is not in yet, so `.bottom` aims at the collapsed
            // row and leaves what the click asked for below the fold. This also
            // covers expanding via the disclosure triangle itself, which sits at
            // the bottom edge for exactly the same reason.
            .onChange(of: aboutExpanded) { isOpen in
                guard isOpen else { return }
                withAnimation { proxy.scrollTo(kAboutAnchor, anchor: .bottom) }
            }
        }
        // NO .navigationTitle here. Inside the NSHostingController-hosted
        // NavigationSplitView, a detail's navigationTitle becomes the WINDOW's
        // title -- so opening a feature renamed the window to that feature, and
        // it stuck there after navigating away ("Bing Daily Wallpaper" over the
        // Home page). The page names itself in-content instead (the heading at
        // the top of the Form above); the window title is pinned once, at the
        // shell in HomepageView. A gate keeps it the only one -- see
        // LocalizationTests.testWindowTitleIsDeclaredOnlyAtTheShell.
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

// MARK: - Detail header

/// Identity + state in one line: glyph, name, version, and the enable switch.
/// The switch is here as well as in the sidebar row because this is the surface
/// you configure a feature from, and a pane of live-looking controls for a
/// DISABLED feature is the one thing the old header could not tell you.
private struct FeatureDetailHeader: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo
    /// Opens (and scrolls to) the About section -- owned by the parent, since
    /// the section it reveals is the parent's.
    let showAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: feature.failed ? "exclamationmark.triangle.fill" : featureIcon(feature))
                    .foregroundStyle(feature.failed ? Color.red : categoryColor(feature.category))
                    .font(.title3)
                Text(feature.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if !feature.version.isEmpty {
                    Text(feature.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.14)))
                        // First to go when the pane is narrow: the name and the
                        // switch are both load-bearing, a version number is not.
                        .layoutPriority(-1)
                }
                if feature.isExtension {
                    // User-extension badge: this code came from the user's own
                    // extensions folder, not the built-in catalog -- worth a
                    // glance-level marker wherever the feature is configured.
                    Text(Strings.t("settings.extension_badge", default: "Extension"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.14)))
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { feature.enabled },
                    set: { store.requestSetEnabled(feature.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(feature.kind == "failed")   // a never-registered module can't be toggled
                .accessibilityLabel(feature.name)
            }
            if !feature.description.isEmpty {
                // One line only, with the rest a click away. The full text still
                // lives in About -- and on the gallery card, which is where a user
                // deciding WHETHER to enable this reads it.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(feature.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button(action: showAbout) {
                        HStack(spacing: 2) {
                            Text(Strings.t("settings.about", default: "About"))
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shortcut row

/// One rebindable action: a single line carrying its label and current binding,
/// expanding in place to the full editor. The collapsed line is what makes a
/// feature with many actions readable -- text_actions has 11, which as stacked
/// editors was ~2,200pt of pane before the options were reached.
private struct TriggerRow: View {
    @ObservedObject var store: SettingsStore
    let feature: FeatureInfo
    let action: ActionInfo

    // Per ROW, deliberately -- not one "which row is open" Optional on the
    // parent. That accordion looked tidier and quietly threw work away:
    // TriggerEditor holds the whole pending edit (mods, key, follows, the
    // recorded-but-not-Applied combo) in its own @State, and a DisclosureGroup
    // tears its content down on collapse -- so opening a second row discarded
    // the first row's unapplied shortcut, on a click that reads as navigation.
    // Per-row state means only an explicit collapse can drop an edit.
    @State private var expanded: Bool

    init(store: SettingsStore, feature: FeatureInfo, action: ActionInfo, startsExpanded: Bool) {
        self.store = store
        self.feature = feature
        self.action = action
        _expanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TriggerEditor(store: store, feature: feature, action: action)
                // Remount when the bound trigger changes so local edit
                // state re-seeds from the new current spec.
                .id("\(feature.id)|\(action.id)|\(action.triggerDesc)")
        } label: {
            HStack(spacing: 6) {
                Text(action.label)
                // The "why this key" hint survives collapsing as a badge -- it is
                // the one teaching device this layout could otherwise cost, and it
                // only ever describes the DEFAULT binding (hidden once rebound,
                // same rule the expanded hint follows).
                if !action.mnemonic.isEmpty && !action.triggerOverridden {
                    Image(systemName: "lightbulb")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(action.mnemonic)
                }
                Spacer(minLength: 8)
                let glyph = shortcutGlyph(action.trigger)
                if glyph.isEmpty {
                    Text(Strings.t("settings.no_shortcut", default: "None"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ShortcutPill(glyph: glyph)
                }
            }
            // Without this the glyph pill is a separate element and a
            // screen-reader user hears the label with no binding attached.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(action.label), \(action.triggerDesc)")
            // The lightbulb carries the mnemonic as a .help tooltip, which is
            // mouse-only; combining the row drops it from the accessibility tree
            // entirely, so it is restated as a hint -- under the SAME
            // rebound-hides-it condition as the badge, since the mnemonic
            // explains the DEFAULT key and misleads once that key is gone.
            .accessibilityHint(action.triggerOverridden ? "" : action.mnemonic)
        }
    }
}

// MARK: - About & capabilities

/// The read-once half of the pane: what the feature does, its version, and what
/// it can reach -- behind one closed disclosure.
///
/// The capability list keeps its own contract. The empty case is rendered, not
/// skipped, and that is the deliberate part: 13 of the catalog's features
/// declare nothing, and "this one touches only windows and panels" is a real
/// answer the user wants. A section that simply vanished would be
/// indistinguishable from a feature whose reach nobody had labelled -- which is
/// exactly the ambiguity the capability work exists to remove. Collapsed is not
/// vanished: the row names the capabilities it is holding, so the count is
/// legible without opening it.
private struct AboutSection: View {
    let feature: FeatureInfo
    @Binding var expanded: Bool

    /// A module that never loaded -- the synthesized load-failure row, the only
    /// producer of `kind == "failed"`. Its `capabilities` were never read, which
    /// is a different thing from a feature that HAS none.
    private var unread: Bool { feature.kind == "failed" }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                if !feature.description.isEmpty {
                    Text(feature.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !feature.version.isEmpty {
                    LabeledContent(Strings.t("settings.version", default: "Version"), value: feature.version)
                }
                // `kind == "failed"`, NOT `failed`: the two say different things.
                // A module that never loaded has no declarations to report, so it
                // gets no capability verdict at all -- the "touches nothing"
                // reassurance would be an affirmative safety claim about the one
                // feature nothing is known about. But `failed` is ALSO set when a
                // fully-parsed feature merely threw in start(), and there the
                // capabilities were read and must still be shown: reporting less
                // reach than a feature has is the one failure this surface must
                // not have (see capabilityInfo in FeatureChrome.swift).
                if !unread { capabilityRows }
            } label: {
                HStack(spacing: 6) {
                    Text(Strings.t("settings.about_and_permissions", default: "About & permissions"))
                    Spacer(minLength: 8)
                    // Names the reach rather than counting it: "Browser, Network"
                    // answers the question the section exists for without opening
                    // it, where "2 capabilities" only says one is worth opening.
                    if !unread {
                        if feature.capabilities.isEmpty {
                            Image(systemName: "checkmark.shield")
                                .foregroundStyle(.secondary)
                                .help(Strings.t("settings.capabilities_none",
                                                default: "Nothing beyond windows, panels and its own settings."))
                        } else {
                            Text(sortedCapabilities(feature.capabilities)
                                    .map { capabilityInfo($0).label }
                                    .joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
            .id(kAboutAnchor)
        }
    }

    /// Every row states its own leading alignment. A grouped Form centers a row
    /// it cannot size, and a DisclosureGroup's content is NOT laid out as form
    /// rows -- without these frames the intrinsic-width rows stair-step to the
    /// right, each indented by its own width.
    @ViewBuilder
    private var capabilityRows: some View {
        Text(Strings.t("settings.capabilities", default: "What it can reach"))
            .font(.callout.weight(.medium))
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        if feature.capabilities.isEmpty {
            Label(Strings.t("settings.capabilities_none",
                            default: "Nothing beyond windows, panels and its own settings."),
                  systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(sortedCapabilities(feature.capabilities), id: \.self) { cap in
                let info = capabilityInfo(cap)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: info.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.label)
                        Text(info.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
                if store.isOptionOverridden(featureId, opt) && !opt.isRowEditor { resetButton }
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
                if store.isOptionOverridden(featureId, opt) && !opt.isRowEditor {
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
                    onChange: { store.setOptionValue(featureId, opt, $0) },
                    // Each site is its own action (menubar submenu row, palette
                    // entry, bindable in the Shortcut Map), and an action set +
                    // its labels only re-derive on register -- so adding,
                    // removing or renaming one reloads the catalog. The editor
                    // picks those moments (never per keystroke).
                    reload: { store.reload() }
                )
            }
        case "aliasList":
            VStack(alignment: .leading, spacing: 4) {
                if !opt.collapsible { Text(opt.label) }
                // No `reload`: an alias creates no action and renames nothing, so
                // the catalog needs no re-register -- the feature re-reads the
                // option on every open.
                AliasListEditor(
                    json: store.optionValue(featureId, opt) as? String
                        ?? (opt.defaultValue as? String ?? ""),
                    onChange: { store.setOptionValue(featureId, opt, $0) })
            }
        case "placementList":
            VStack(alignment: .leading, spacing: 4) {
                if !opt.collapsible { Text(opt.label) }
                PlacementListEditor(
                    json: store.optionValue(featureId, opt) as? String
                        ?? (opt.defaultValue as? String ?? ""),
                    onChange: { store.setOptionValue(featureId, opt, $0) },
                    // Adding/removing/renaming a snap changes the feature's action
                    // set/labels, which only re-derive on register -- so a commit
                    // reloads the catalog to bind the new snap's action live.
                    reload: { store.reload() },
                    // The shortcut lives in the row: read/write the hotkey of the
                    // snap's "preset_<id>" action so shape + key sit in one place.
                    comboFor: { pid in
                        let a = store.features.first { $0.id == featureId }?
                            .actions.first { $0.id == "preset_" + pid }
                        if let t = a?.trigger, t.type == "hotkey" {
                            return SnapCombo(mods: Set(t.mods), key: t.key)
                        }
                        return SnapCombo(mods: [], key: "")
                    },
                    bind: { pid, mods, key in
                        // keyish() is the canonical "editor fields -> spec" factory
                        // (mod order + key casing), shared with the trigger editor.
                        // Returns setTrigger's refusal reason (nil on success) so the
                        // row can revert a rejected combo instead of showing a phantom.
                        store.setTrigger(featureId, "preset_" + pid,
                                         TriggerSpec.keyish(mods: mods, key: key, follows: ""))
                    }
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
                // 78 is the height these scenes are composed for -- the Gallery
                // card's preview band uses it. At 54 the chooser mock drew past
                // the box it reported, and the neighbours, laid out against the
                // reported 54, rendered underneath it. The clip keeps that
                // failure from returning: whatever a future scene's intrinsic
                // height is, the declared box is the drawn box.
                .frame(height: 78)
                .frame(maxWidth: .infinity)
                .clipped()
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

        // Both warning rows pin their own leading edge. These are intrinsic-width
        // Labels, and this editor is now disclosed inside a TriggerRow rather
        // than sitting as a Section's direct content -- a grouped Form centers a
        // row it cannot size, which would drift the warnings toward the middle in
        // exactly the state the user is being warned in.
        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Soft, advisory warnings (system / common-app collisions). Unlike a
        // hard conflict these never block Apply -- the user may still want the
        // key; they just see what it costs.
        ForEach(advisories, id: \.self) { warning in
            Label(warning, systemImage: "info.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
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
