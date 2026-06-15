import SwiftUI
import AppKit

// The Homepage: the "cool home" shell. A single window with a sidebar that
// routes to the landing Dashboard and docks the already-shipped lenses
// (Feature Gallery, Shortcut Map, Automation Timeline) as tabs -- so there is
// one home that says "here's your Hammerdeck: what's on, what it's doing right
// now, and what it can do," and is the doorway to the deeper views.
//
// Pure shell + presentation: every tab reuses the SAME view struct and store
// the standalone windows use (no duplicated logic), and the Dashboard reads
// only data already flowing through registry.describe(). Settings stays its own
// window (master-detail nests badly inside the shell's split) -- one click from
// the sidebar, plus the Gallery's card deep-link.

enum HomeDestination: String, CaseIterable, Identifiable, Hashable {
    case home, features, shortcuts, timeline
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:      return "Home"
        case .features:  return "Features"
        case .shortcuts: return "Shortcuts"
        case .timeline:  return "Timeline"
        }
    }
    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .features:  return "square.grid.2x2.fill"
        case .shortcuts: return "keyboard.fill"
        case .timeline:  return "clock.fill"
        }
    }
}

/// Holds the selected shell tab outside the SwiftUI view tree, so the menubar
/// can route "Shortcut Map…" etc. straight to the right tab of the live window.
@MainActor
final class HomeNav: ObservableObject {
    @Published var destination: HomeDestination = .home
}

struct HomepageView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var nav: HomeNav

    /// Opens the Settings window focused on a feature (set by the host in Boot).
    let openSettings: (String?) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.destination) {
                ForEach(HomeDestination.allCases) { dest in
                    Label(dest.title, systemImage: dest.icon).tag(dest)
                }
                Section {
                    Button {
                        openSettings(nil)
                    } label: {
                        Label("Settings…", systemImage: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.reload()
                    } label: {
                        Label("Reload Features", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 7) {
                    Image(systemName: "hammer.fill").foregroundStyle(.tint)
                    Text("Hammerdeck").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            }
        } detail: {
            switch nav.destination {
            case .home:
                DashboardView(store: store,
                              goTo: { nav.destination = $0 },
                              openSettings: { openSettings(nil) })
            case .features:
                FeatureGalleryView(store: store, openSettings: { openSettings($0) })
            case .shortcuts:
                ShortcutMapView(store: store)
            case .timeline:
                AutomationTimelineView(store: store)
            }
        }
        // The shell is the single source of truth for the minimum size; the
        // embedded tab views no longer impose their own (they're not standalone
        // windows anymore). Wide enough to hold the Shortcut Map's fixed columns
        // (sidebar + ~780) without clipping.
        .frame(minWidth: 960, minHeight: 560)
        .onAppear { store.refresh() }
    }
}

// MARK: - Dashboard (the landing)

struct DashboardView: View {
    @ObservedObject var store: SettingsStore
    let goTo: (HomeDestination) -> Void
    let openSettings: () -> Void

    @State private var nowMinutes = AutomationTimelineView.currentMinutes()
    @State private var conflicts: Set<String> = []
    @State private var axTrusted = false
    // The tip feature is pinned for the visit so enabling it from the card
    // doesn't make the tip jump to a different feature mid-glance.
    @State private var tipId: String?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Home").font(.title2.weight(.semibold))
            Text("What's on, what it's doing right now, and what it can do.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Tip of the day

    /// The feature pinned for this visit (resolved on appear), else today's pick.
    private var tipFeature: FeatureInfo? {
        if let tipId, let f = store.features.first(where: { $0.id == tipId }) { return f }
        return Self.tipFeature(store.features, dayOfYear: Self.currentDayOfYear())
    }

    @ViewBuilder private var tipCard: some View {
        if let f = tipFeature {
            DashCard(title: "Tip of the day", icon: "lightbulb.fill", tint: .yellow) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(categoryColor(f.category).opacity(0.20))
                            .frame(width: 34, height: 34)
                        Image(systemName: categoryIcon(f.category))
                            .foregroundStyle(categoryColor(f.category))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.enabled ? "Did you know?" : "You haven't turned this on yet")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(f.name).font(.headline)
                        Text(f.description.isEmpty ? "No description." : f.description)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        HStack(spacing: 8) {
                            tipShortcut(f)
                            Spacer()
                            if !f.enabled {
                                Button("Enable") { store.setEnabled(f.id, true) }
                            }
                            Button("Show in Gallery") { goTo(.features) }
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
            Label("always on", systemImage: "infinity")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            let glyph = shortcutGlyph(f.actions.first?.trigger)
            if glyph.isEmpty {
                Text("no shortcut bound").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(glyph)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.14)))
            }
        }
    }

    // MARK: Right now card

    private var rightNowCard: some View {
        DashCard(title: "Right now", icon: "bolt.horizontal.fill", tint: .blue) {
            let items = Self.upcoming(store.features, now: nowMinutes, limit: 4)
            if items.isEmpty {
                Text("Nothing scheduled soon. Enable a time-based feature, or bind an "
                     + "action to a schedule.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Browse features") { goTo(.features) }
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
                Button("Open Timeline") { goTo(.timeline) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        DashCard(title: "Status", icon: "checklist", tint: .green) {
            let total = store.features.count
            let enabled = store.features.filter { $0.enabled }.count
            let failed = store.features.filter { $0.failed }
            statusRow("checkmark.circle.fill", .green,
                      "\(enabled) of \(total) features enabled")
            if conflicts.isEmpty {
                statusRow("checkmark.circle.fill", .green, "No shortcut conflicts")
            } else {
                Button { goTo(.shortcuts) } label: {
                    statusRow("exclamationmark.triangle.fill", .orange,
                              "\(conflicts.count) shortcut "
                              + (conflicts.count == 1 ? "conflict" : "conflicts"))
                }
                .buttonStyle(.plain)
            }
            if failed.isEmpty {
                statusRow("checkmark.circle.fill", .green, "No failed plugins")
            } else {
                Button { openSettings() } label: {
                    statusRow("xmark.octagon.fill", .red,
                              "\(failed.count) failed: "
                              + failed.map { $0.name }.joined(separator: ", "))
                }
                .buttonStyle(.plain)
            }
            statusRow(axTrusted ? "checkmark.circle.fill" : "lock.fill",
                      axTrusted ? .green : .orange,
                      axTrusted ? "Accessibility granted"
                                : "Accessibility not granted (window features limited)")
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
        store.refresh()
        nowMinutes = AutomationTimelineView.currentMinutes()
        conflicts = store.conflictedFeatureIds()
        axTrusted = store.accessibilityTrusted()
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
        if mins == 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        return "in \(mins / 60)h \(mins % 60)m"
    }

    private func fmtHM(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

// MARK: - A dashboard card shell

private struct DashCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.headline)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.15)))
    }
}
