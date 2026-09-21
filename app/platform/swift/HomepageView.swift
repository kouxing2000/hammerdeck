import SwiftUI
import AppKit

// The Homepage: the "cool home" shell. A single window with a sidebar that
// routes to the landing Dashboard and docks the already-shipped lenses
// (Feature Gallery, Shortcut Map, Automation Timeline) as tabs -- so there is
// one home that says "here's your Hammerdeck: what's on, what it's doing right
// now, and what it can do," and is the doorway to the deeper views.
//
// Pure shell + presentation: every tab reuses the SAME view struct and store
// (no duplicated logic), and the Dashboard reads only data already flowing
// through registry.describe(). Settings is embedded as its own tab too -- it
// uses an HSplitView (not a nested NavigationSplitView), so it docks cleanly in
// the shell's detail column alongside the Gallery / Shortcut Map / Timeline.

enum HomeDestination: Hashable, Identifiable {
    case home, features, shortcuts, rules, timeline, settings
    case feature(String)   // a feature-contributed native page, keyed by feature id

    var id: String { rawValue }

    /// Built-in tabs (the feature pages are appended dynamically by the sidebar).
    static let builtins: [HomeDestination] = [.home, .features, .shortcuts, .rules, .timeline, .settings]

    /// Stable string key -- also the persisted / deep-link form. Feature pages
    /// serialize as "feature:<id>" so Boot's rawValue deep-link round-trips.
    var rawValue: String {
        switch self {
        case .home:             return "home"
        case .features:         return "features"
        case .shortcuts:        return "shortcuts"
        case .rules:            return "rules"
        case .timeline:         return "timeline"
        case .settings:         return "settings"
        case .feature(let fid): return "feature:" + fid
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "home":      self = .home
        case "features":  self = .features
        case "shortcuts": self = .shortcuts
        case "rules":     self = .rules
        case "timeline":  self = .timeline
        case "settings":  self = .settings
        default:
            guard rawValue.hasPrefix("feature:") else { return nil }
            self = .feature(String(rawValue.dropFirst("feature:".count)))
        }
    }

    var title: String {
        switch self {
        case .home:             return Strings.t("home.nav_home", default: "Home")
        case .features:         return Strings.t("home.nav_features", default: "Features")
        case .shortcuts:        return Strings.t("home.nav_shortcuts", default: "Shortcuts")
        case .rules:            return Strings.t("home.nav_rules", default: "Rules")
        case .timeline:         return Strings.t("home.nav_timeline", default: "Timeline")
        case .settings:         return Strings.t("home.nav_settings", default: "Settings")
        case .feature(let fid): return fid   // the sidebar shows the manifest title instead
        }
    }
    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .features:  return "square.grid.2x2.fill"
        case .shortcuts: return "keyboard.fill"
        case .rules:     return "wand.and.stars"
        case .timeline:  return "clock.fill"
        case .settings:  return "gearshape.fill"
        case .feature:   return "doc"
        }
    }
}

/// Holds the selected shell tab outside the SwiftUI view tree, so the menubar
/// can route "Shortcut Map…" etc. straight to the right tab of the live window.
@MainActor
final class HomeNav: ObservableObject {
    @Published var destination: HomeDestination = .home
    /// Drives the opt-in Feature Tour sheet: the Dashboard's "Take the tour"
    /// button, and the debug control channel via StatusBar.presentTour. NOT first
    /// launch, which lands on the Dashboard so the grant and the demo come first.
    @Published var showTour = false
}

struct HomepageView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var nav: HomeNav

    /// Jump to the embedded Settings tab, optionally focused on a feature (the
    /// Gallery's card deep-link). Selection lives on the store; SettingsPane reads it.
    private func showSettings(_ id: String? = nil) {
        if let id { store.selectedFeatureId = id }
        nav.destination = .settings
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.destination) {
                // The content lenses up top; Settings + utilities set apart below.
                ForEach(HomeDestination.builtins.filter { $0 != .settings }) { dest in
                    Label(dest.title, systemImage: dest.icon).tag(dest)
                }
                // Feature-contributed native pages (manifest `page` + a registered
                // view) -- the sidebar is data-driven, so a new page just appears.
                let pages = store.featurePages()
                if !pages.isEmpty {
                    Section(Strings.t("home.feature_pages", default: "Feature Pages")) {
                        ForEach(pages) { f in
                            Label(f.page?.title ?? f.name, systemImage: f.page?.icon ?? "doc")
                                .tag(HomeDestination.feature(f.id))
                        }
                    }
                }
                Section {
                    Label(HomeDestination.settings.title,
                          systemImage: HomeDestination.settings.icon)
                        .tag(HomeDestination.settings)
                    Button {
                        store.userReload()
                    } label: {
                        Label(Strings.t("home.reload_features", default: "Reload Features"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 7) {
                    Image(systemName: "hammer.fill").foregroundStyle(.tint)
                    Text(AppInfo.displayName).font(.headline)
                    // The app's own version, which otherwise appears nowhere a
                    // user can see -- only in a bug-report mail subject. Here
                    // rather than only in the About panel: the main menu bar is
                    // unreachable while another app is frontmost, and absent
                    // entirely when "Show in Dock" is off, which is exactly how a
                    // menubar utility is usually run. Omitted, not faked, in a dev
                    // `swift run`, which has no Info.plist and so no version.
                    if let v = AppInfo.version {
                        Text(v).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(String(format: Strings.t("home.version",
                                                                         default: "Version %@"), v))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            }
        } detail: {
            switch nav.destination {
            case .home:
                DashboardView(store: store,
                              goTo: { nav.destination = $0 },
                              openSettings: { showSettings() },
                              startTour: { nav.showTour = true })
            case .features:
                FeatureGalleryView(store: store, openSettings: { showSettings($0) })
            case .shortcuts:
                ShortcutMapView(store: store)
            case .rules:
                RulesPageView(store: store)
            case .timeline:
                AutomationTimelineView(store: store)
            case .settings:
                SettingsPane(store: store)
            case .feature(let fid):
                if store.showsPage(fid),
                   let view = FeaturePageRegistry.shared.view(for: fid, store: store) {
                    view
                } else {
                    // Stale selection (feature disabled or vanished on reload, page
                    // declared but no registered view) -- the sidebar no longer lists
                    // it; show a neutral placeholder.
                    Text(Strings.t("home.page_unavailable", default: "This page is unavailable.")).foregroundStyle(.secondary)
                }
            }
        }
        // The shell is the single source of truth for the minimum size; the
        // embedded tab views no longer impose their own (they're not standalone
        // windows anymore). Wide enough to hold the Shortcut Map's fixed columns
        // (sidebar + ~780) without clipping.
        .frame(minWidth: 960, minHeight: 560)
        // Pin the WINDOW title to the app's name, once, at the shell. Inside an
        // NSHostingController-hosted NavigationSplitView a DETAIL's
        // .navigationTitle becomes the window title -- so a feature page used to
        // rename the window to that feature and leave it there after navigating
        // away ("Bing Daily Wallpaper" sitting over the Home page). Those detail
        // titles are gone, and declaring the real one here states the intent
        // rather than leaving the title to whatever StatusBar set at creation.
        // This does NOT defend itself -- a detail's title would win again -- so
        // the invariant is held by a gate:
        // HostChromeTests.testWindowTitleIsDeclaredOnlyAtTheShell.
        .navigationTitle(AppInfo.displayName)
        .onAppear { store.refresh() }
        // A timeline rule-click deep-links here: switch to the Rules tab, where
        // RulesPageView consumes selectedRuleId and opens that rule for editing.
        .onChange(of: store.selectedRuleId) { id in
            if id != nil { nav.destination = .rules }
        }
        // A grant (e.g. Accessibility) lands out-of-process while this window is
        // already open; refreshing when the app reactivates is what makes
        // store.axTrusted -- and the "Needs Accessibility -- Grant" badges that
        // read it -- actually update on return from System Settings.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in store.refresh() }
        // First-run onboarding (and replayable later): a large auto-playing
        // preview per feature with a single "Add". Dismissing refreshes so the
        // shell reflects whatever the user just enabled.
        .sheet(isPresented: $nav.showTour) {
            FeatureTourView(store: store) {
                nav.showTour = false
                store.refresh()
            }
        }
    }
}

// MARK: - Dashboard (the landing)

struct DashboardView: View {
    @ObservedObject var store: SettingsStore
    let goTo: (HomeDestination) -> Void
    let openSettings: () -> Void
    let startTour: () -> Void

    @State private var nowMinutes = AutomationTimelineView.currentMinutes()
    @State private var conflicts: Set<String> = []
    // The tip feature is pinned for the visit so enabling it from the card
    // doesn't make the tip jump to a different feature mid-glance.
    @State private var tipId: String?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                getStartedCard
                tipCard
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    rightNowCard
                    statusCard
                }
            }
            .padding(18)
        }
        .onAppear { refresh() }
        .task(id: catalogSignature) { conflicts = store.conflictedFeatureIds() }
        .onReceive(tick) { _ in nowMinutes = AutomationTimelineView.currentMinutes() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.t("home.nav_home", default: "Home")).font(.title2.weight(.semibold))
                Text(Strings.t("home.header_subtitle", default: "What's on, what it's doing right now, and what it can do."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { startTour() } label: {
                Label(Strings.t("home.take_tour", default: "Take the tour"), systemImage: "sparkles")
            }
            .help(Strings.t("home.take_tour_help", default: "Browse every feature with a live preview and add the ones you want"))
        }
    }

    // MARK: Get-started hero (the first-run golden path, and the blank-start net)

    /// The one card a new user must read, in three states, first match wins.
    /// Pinned above every other Dashboard card because on a fresh install the
    /// others are at their least interesting ("Nothing scheduled soon").
    ///
    /// 1. **Empty deck** -- the recovery path, and FIRST because it is the
    ///    narrowest. Ungranted-and-empty is not a corner: the seven spine features
    ///    that need Accessibility are exactly the ones a user turns off because
    ///    they appear to do nothing, and `enableEssentials()` has no other caller,
    ///    so ranking the grant above this would gate the only way back from an
    ///    empty deck behind the permission being declined. Clicking Enable
    ///    Essentials refills the deck, and the very next render falls through to
    ///    the grant below -- the two arrive in sequence rather than competing.
    /// 2. **Ungranted** -- the up-front Accessibility ask WITH the why. Most of
    ///    the curated spine needs it, and one of them (Pointer Follows) is a pure
    ///    service with no trigger, so nothing the user could press would ever
    ///    onboard it. This is the only surface that can.
    /// 3. **Granted, unacknowledged** -- the demo moment: the deck hotkey, so the
    ///    first thing a stranger does is watch their OWN windows move.
    ///
    /// State 1 was the whole card until the spine started shipping enabled, which
    /// made `enabledCount == 0` unreachable on a fresh install and left the
    /// surface stranded -- it is a state here, not a separate card.
    @ViewBuilder private var getStartedCard: some View {
        let enabledCount = store.features.filter { $0.enabled }.count
        if enabledCount == 0 {
            let essentials = store.features.filter { $0.recommended && !$0.failed }
            DashCard(title: Strings.t("home.get_started", default: "Get started"), icon: "sparkles", tint: .accentColor) {
                Text(Strings.t("home.deck_empty", default: "Your deck is empty. Turn on a few essentials to get going, or browse the whole catalog with a live preview."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if !essentials.isEmpty {
                        Button { store.enableEssentials() } label: {
                            Label(String(format: Strings.t("home.enable_essentials", default: "Enable %d Essentials"), essentials.count), systemImage: "star.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button { startTour() } label: {
                        Label(Strings.t("home.take_tour", default: "Take the tour"), systemImage: "play.fill")
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        } else if !store.axTrusted {
            DashCard(title: Strings.t("home.get_started", default: "Get started"),
                     icon: "hand.raised.fill", tint: .accentColor) {
                Text(String(format: Strings.t("home.ax_why",
                    default: "%@ moves your windows from the keyboard. macOS asks for one permission before any app may do that -- grant it once and the window features that shipped switched on start working."),
                    AppInfo.displayName))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { store.promptAccessibility() } label: {
                        Label(Strings.t("home.ax_grant", default: "Grant Accessibility"),
                              systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { startTour() } label: {
                        Label(Strings.t("home.take_tour", default: "Take the tour"),
                              systemImage: "play.fill")
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        } else if !firstRunAcknowledged, let (name, glyph) = deckDemoShortcut {
            DashCard(title: Strings.t("home.try_it", default: "Try it now"),
                     icon: "sparkles", tint: .accentColor) {
                // The glyph comes from the LIVE catalog, never a literal: the user
                // may have rebound it, and a wrong shortcut costs most in the one
                // place it is the only instruction on screen.
                Text(String(format: Strings.t("home.try_deck",
                    default: "Press %1$@ with a few windows open -- %2$@ tiles them, and the one you focus becomes a large hero with the rest peeking behind."),
                    glyph, name))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { acknowledgeFirstRun() } label: {
                        Label(Strings.t("home.got_it", default: "Got it"),
                              systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { acknowledgeFirstRun(); startTour() } label: {
                        Label(Strings.t("home.browse_catalog", default: "Browse the catalog"),
                              systemImage: "play.fill")
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    /// The demo feature's localized name and its CURRENT shortcut glyph, or nil
    /// when it is disabled, failed, or bound to nothing a user can press -- state
    /// 3 collapses rather than printing an instruction that cannot work.
    ///
    /// The ACTION is looked up by id, never positionally: this glyph is the only
    /// instruction on screen at that moment, and `actions.first` would silently
    /// print a different action's shortcut the day one is added ahead of it.
    /// Static and pure so it is testable off a plain feature list, like
    /// `tipFeature` / `upcoming` / `relative` in this same struct.
    static func demoShortcut(_ features: [FeatureInfo]) -> (name: String, glyph: String)? {
        guard let f = features.first(where: { $0.id == demoFeatureId }),
              f.enabled, !f.failed,
              let a = f.actions.first(where: { $0.id == demoActionId }),
              let t = a.trigger, t.type == "hotkey" || t.type == "chord"
        else { return nil }
        let glyph = shortcutGlyph(t)
        return glyph.isEmpty ? nil : (f.name, glyph)
    }

    private var deckDemoShortcut: (name: String, glyph: String)? {
        Self.demoShortcut(store.features)
    }

    /// window_deck is the demo because it is the loudest: it moves every window on
    /// the screen at once, so the wow moment needs no explaining. Its `toggle`
    /// action is the one bound to the hotkey the card names.
    static let demoFeatureId = "window_deck"
    static let demoActionId = "toggle"

    /// Whether the user has dismissed the try-it step. `@AppStorage`, so the view
    /// declares its dependency on the default rather than reading it through a
    /// computed property and repainting via an unrelated `store.refresh()` --
    /// which redrew by accident of a `@Published` write, and did nothing at all on
    /// the path where `refresh()` early-returns on a failed catalog read.
    ///
    /// Boot SEEDS this true for anyone whose first run already happened
    /// (`FirstRunPreference.seedIfUpgrading`), so an existing user does not get a
    /// first-run card injected at the top of their Dashboard on upgrade.
    @AppStorage(FirstRunPreference.ackKey) private var firstRunAcknowledged = false

    private func acknowledgeFirstRun() { firstRunAcknowledged = true }

    // MARK: Tip of the day

    /// The feature pinned for this visit (resolved on appear), else today's pick.
    private var tipFeature: FeatureInfo? {
        if let tipId, let f = store.features.first(where: { $0.id == tipId }) { return f }
        return Self.tipFeature(store.features, dayOfYear: Self.currentDayOfYear())
    }

    @ViewBuilder private var tipCard: some View {
        if let f = tipFeature {
            DashCard(title: Strings.t("home.tip_of_day", default: "Tip of the day"), icon: "lightbulb.fill", tint: .yellow) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(categoryColor(f.category).opacity(0.20))
                            .frame(width: 34, height: 34)
                        Image(systemName: featureIcon(f))
                            .foregroundStyle(categoryColor(f.category))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.enabled ? Strings.t("home.did_you_know", default: "Did you know?") : Strings.t("home.not_enabled_yet", default: "You haven't turned this on yet"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(f.name).font(.headline)
                        Text(f.description.isEmpty ? Strings.t("home.no_description", default: "No description.") : f.description)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        HStack(spacing: 8) {
                            tipShortcut(f)
                            Spacer()
                            if !f.enabled {
                                Button(Strings.t("home.enable", default: "Enable")) { store.requestSetEnabled(f.id, true) }
                            }
                            Button(Strings.t("home.show_in_gallery", default: "Show in Gallery")) { goTo(.features) }
                                .buttonStyle(.link)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder private func tipShortcut(_ f: FeatureInfo) -> some View {
        if f.actions.isEmpty {
            Label(Strings.t("home.always_on", default: "always on"), systemImage: "infinity")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            let glyph = shortcutGlyph(f.actions.first?.trigger)
            if glyph.isEmpty {
                Text(Strings.t("home.no_shortcut_bound", default: "no shortcut bound")).font(.caption2).foregroundStyle(.tertiary)
            } else {
                ShortcutPill(glyph: glyph)
            }
        }
    }

    // MARK: Right now card

    private var rightNowCard: some View {
        DashCard(title: Strings.t("home.right_now", default: "Right now"), icon: "bolt.horizontal.fill", tint: .blue) {
            let items = Self.upcoming(store.features, now: nowMinutes, limit: 4)
            if items.isEmpty {
                Text(Strings.t("home.nothing_scheduled", default: "Nothing scheduled soon. Enable a time-based feature, or bind an action to a schedule."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(Strings.t("home.browse_features", default: "Browse features")) { goTo(.features) }
                    .buttonStyle(.link).font(.caption)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Circle().fill(categoryColor(item.category)).frame(width: 7, height: 7)
                        Text(fmtHM(item.minutes)).font(.callout.monospacedDigit().weight(.medium))
                            .frame(width: 52, alignment: .leading)
                        Text(item.label).font(.callout).lineLimit(1)
                        Spacer()
                        Text(Self.relative(item.untilNext))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(Strings.t("home.open_timeline", default: "Open Timeline")) { goTo(.timeline) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        DashCard(title: Strings.t("home.status", default: "Status"), icon: "checklist", tint: .green) {
            let total = store.features.count
            let enabled = store.features.filter { $0.enabled }.count
            let failed = store.features.filter { $0.failed }
            statusRow("checkmark.circle.fill", .green,
                      String(format: Strings.t("home.features_enabled", default: "%1$d of %2$d features enabled"), enabled, total))
            if conflicts.isEmpty {
                statusRow("checkmark.circle.fill", .green, Strings.t("home.no_conflicts", default: "No shortcut conflicts"))
            } else {
                Button { goTo(.shortcuts) } label: {
                    statusRow("exclamationmark.triangle.fill", .orange,
                              String(format: Strings.plural("home.shortcut_conflicts", conflicts.count,
                                                            one: "%d shortcut conflict",
                                                            other: "%d shortcut conflicts"), conflicts.count))
                }
                .buttonStyle(.plain)
            }
            if failed.isEmpty {
                statusRow("checkmark.circle.fill", .green, Strings.t("home.no_failed", default: "No failed plugins"))
            } else {
                Button { openSettings() } label: {
                    statusRow("xmark.octagon.fill", .red,
                              String(format: Strings.t("home.failed_list", default: "%1$d failed: %2$@"),
                                     failed.count, failed.map { $0.name }.joined(separator: ", ")))
                }
                .buttonStyle(.plain)
            }
            if store.axTrusted {
                statusRow("checkmark.circle.fill", .green, Strings.t("home.ax_granted", default: "Accessibility granted"))
            } else {
                // Tappable: the silently-no-op window/typing features stay dead
                // until this is granted, so make the row the fix, not just a sign.
                Button { store.promptAccessibility() } label: {
                    statusRow("lock.fill", .orange,
                              Strings.t("home.ax_not_granted", default: "Accessibility not granted — tap to grant (window & typing features need it)"))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func statusRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            Text(text).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    // MARK: data

    private func refresh() {
        store.refresh()   // also updates the published store.axTrusted the status card reads
        nowMinutes = AutomationTimelineView.currentMinutes()
        conflicts = store.conflictedFeatureIds()
        if tipId == nil {
            tipId = Self.tipFeature(store.features, dayOfYear: Self.currentDayOfYear())?.id
        }
    }

    // MARK: tip-of-the-day pick (deterministic per day, testable)

    static func currentDayOfYear() -> Int {
        Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
    }

    /// One feature to surface as today's tip, chosen deterministically by day so
    /// it's stable within a day and rotates across days. Failed plugins are never
    /// tipped; DISABLED features are preferred (the tip's job is rediscovery --
    /// "you have this but aren't using it"), falling back to the whole catalog
    /// once everything is on. Sorted by id so the pick doesn't depend on catalog
    /// ordering.
    static func tipFeature(_ features: [FeatureInfo], dayOfYear: Int) -> FeatureInfo? {
        let usable = features.filter { !$0.failed }
        let disabled = usable.filter { !$0.enabled }
        let pool = (disabled.isEmpty ? usable : disabled).sorted { $0.id < $1.id }
        guard !pool.isEmpty else { return nil }
        return pool[((dayOfYear % pool.count) + pool.count) % pool.count]
    }

    private var catalogSignature: String {
        store.features.map { "\($0.id):\($0.enabled)" }.joined(separator: "|")
    }

    // MARK: upcoming-schedule aggregation (shared, testable)

    struct Upcoming: Identifiable, Equatable {
        let id: String
        let label: String
        let category: String
        let minutes: Int     // minutes since midnight
        let untilNext: Int   // minutes from `now` until the next fire (wrapping)
    }

    /// The next daily-time markers across all ENABLED, non-failed features --
    /// both action `at` triggers and service schedule descriptors. Sorted by
    /// time-until-next-fire (wrapping past midnight), capped at `limit`. Reads
    /// only public FeatureInfo data, so it is unit-testable off the store.
    static func upcoming(_ features: [FeatureInfo], now: Int, limit: Int) -> [Upcoming] {
        var out: [Upcoming] = []
        for f in features where f.enabled && !f.failed {
            for a in f.actions {
                if let t = a.trigger, t.type == "schedule", let at = t.at,
                   let m = AutomationTimelineView.minutesOf(at) {
                    out.append(make(f, f.actions.count > 1 ? a.label : f.name, m, now,
                                    "\(f.id)|\(a.id)"))
                }
            }
            for e in f.schedule where e.kind == "at" {
                if let m = e.minutesOfDay {
                    out.append(make(f, e.label, m, now, "\(f.id)|\(e.id)"))
                }
            }
        }
        return out.sorted { $0.untilNext < $1.untilNext }.prefix(limit).map { $0 }
    }

    private static func make(_ f: FeatureInfo, _ label: String, _ m: Int,
                             _ now: Int, _ id: String) -> Upcoming {
        let d = m - now
        return Upcoming(id: id, label: label, category: f.category, minutes: m,
                        untilNext: d >= 0 ? d : d + 1440)
    }

    static func relative(_ mins: Int) -> String {
        if mins == 0 { return Strings.t("home.relative_now", default: "now") }
        if mins < 60 { return String(format: Strings.t("home.relative_in_min", default: "in %d min"), mins) }
        return String(format: Strings.t("home.relative_in_hm", default: "in %1$dh %2$dm"), mins / 60, mins % 60)
    }

    private func fmtHM(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: - A dashboard card shell

// Shared card shell across the Homepage tabs (Dashboard + the Usage report).
// `onTitleTap`, when set, makes the header a button (e.g. a drill-in's back).
struct DashCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var onTitleTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    init(title: String, icon: String, tint: Color,
         onTitleTap: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; self.tint = tint
        self.onTitleTap = onTitleTap; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.15)))
    }

    @ViewBuilder private var header: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.headline)
        }
        if let onTitleTap {
            Button(action: onTitleTap) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}
