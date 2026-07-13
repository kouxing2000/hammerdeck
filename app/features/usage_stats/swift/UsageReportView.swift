import SwiftUI
import Charts

// The rich Usage Report -- a feature-contributed NATIVE Homepage page (declared
// by usage_stats' manifest `page`, registered in FeaturePageRegistry). It reads
// history through the report.lua reader (so it works even when the usage_stats
// feature is disabled) and renders it with Apple Charts + the house DashCard
// aesthetic. The Lua side computes; this view only presents.
struct UsageReportView: View {
    @ObservedObject var store: SettingsStore

    @State private var range: ReportRange = .week
    @State private var periodsBack = 0          // 0 = current window; +N steps back
    @State private var data: UsageReportData = .empty
    @State private var selectedApp: String?

    private let accent = Color.accentColor
    // Hoisted (NOT created in body): an inline Timer.publish is rebuilt on every
    // re-render, restarting the 30s countdown each time -- and since each fire
    // reassigns the non-Equatable `data`, body re-renders, so the timer could churn
    // and never reach its deadline (defeating the live refresh). A stored publisher
    // ticks at a steady 30s; autoconnect drops it when the view leaves the hierarchy.
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !data.hasData {
                    emptyCard
                } else {
                    heroStrip
                    trendCard
                    if let app = selectedApp,
                       let row = data.apps.first(where: { $0.app == app }) {
                        appDrillCard(row)
                    } else {
                        topAppsCard
                    }
                    detailTableCard
                    rhythmCard
                }
            }
            .padding(18)
        }
        // Reloads on first appear and whenever the range/period changes; selecting an
        // app does NOT change this id, so a drill-in never refetches.
        .task(id: "\(range.rawValue)|\(periodsBack)") { load() }
        // The CURRENT period accrues live (usage_stats writes per-app focus as you
        // work), but .task only fires on a range/period switch -- so the report would
        // sit stale while open. Refresh the live window on a light timer, preserving any
        // drill-in. Historical periods (periodsBack > 0) are static, so skip them.
        .onReceive(refreshTimer) { _ in
            if periodsBack == 0 { load(reset: false) }
        }
    }

    // MARK: data

    // `reset` true (a range/period switch via .task, or Enable): clear the drill-in and
    // blank on a read miss. false (the live-period auto-refresh): keep the drill-in AND
    // the old data on a miss, so a transient read hiccup never flashes an empty report
    // or kicks the user out of an app they drilled into.
    private func load(reset: Bool = true) {
        if reset { selectedApp = nil }
        let b = range.isoBounds(periodsBack: periodsBack)
        if let raw: [String: Any] = store.callValue("features.usage_stats.report", "range",
                                                    [.string(b.from), .string(b.to)]) {
            data = UsageReportData(raw)
        } else if reset {
            data = .empty
        }
    }

    // MARK: header (title + range switcher + stepper)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.t("usage.title", default: "Usage")).font(.title2.weight(.semibold))
                Text(range.label(periodsBack: periodsBack))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            HStack(spacing: 4) {
                Button { periodsBack += 1 } label: { Image(systemName: "chevron.left") }
                    .help(Strings.t("usage.earlier", default: "Earlier"))
                Button { if periodsBack > 0 { periodsBack -= 1 } } label: { Image(systemName: "chevron.right") }
                    .disabled(periodsBack == 0)
                    .help(Strings.t("usage.later", default: "Later"))
            }
            .buttonStyle(.borderless)
            Picker("", selection: $range) {
                ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
    }

    // MARK: hero stat strip

    private var heroStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 320), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            statTile(Strings.t("usage.totalActive", default: "Total active"), usageTimeString(data.total), delta: totalDelta)
            statTile(Strings.t("usage.dailyAvg", default: "Daily avg"), usageTimeString(data.dailyAvg),
                     sub: String(format: Strings.plural("usage.activeDays", data.activeDays,
                                                        one: "%d active day", other: "%d active days"),
                                 data.activeDays))
            statTile(Strings.t("usage.busiestApp", default: "Busiest app"), data.busiestApp ?? "—",
                     sub: data.busiestApp == nil ? nil : usageTimeString(data.apps.first?.secs ?? 0))
            let at = activeTile
            statTile(at.title, at.value, sub: at.sub)
        }
    }

    /// (text, isUp) percent delta vs the previous equal-length period, or nil
    /// when there's no full prior period to compare against (sparse-data rule),
    /// or when the change rounds to flat (an arrow on "0%" reads as a trend).
    private var totalDelta: (String, Bool)? {
        guard data.prevHasData, data.prevTotal > 0 else { return nil }
        let pct = (data.total - data.prevTotal) / data.prevTotal * 100
        let rounded = Int(pct.rounded())
        if rounded == 0 { return nil }
        return ("\(rounded > 0 ? "+" : "")\(rounded)%", rounded > 0)
    }

    /// The 4th hero tile. For Today it's the waking window (wake–sleep, with the
    /// clock range as sub). For a multi-day range a single wake–sleep span would
    /// be meaningless (it'd read Monday's wake to Friday's sleep as one day), so
    /// it shows the average machine-awake time per day that had a session.
    private var activeTile: (title: String, value: String, sub: String?) {
        if range == .today {
            guard let w = data.firstWakeMin, let s = data.lastSleepMin, s > w else {
                return (Strings.t("usage.activeHours", default: "Active hours"), "—", nil)
            }
            return (Strings.t("usage.activeHours", default: "Active hours"), usageTimeString(Double((s - w) * 60)),
                    "\(clockLabel(w)) – \(clockLabel(s))")
        }
        let sessionDays = Set(data.sessions.map(\.date)).count
        guard sessionDays > 0, data.activeMinutes > 0 else { return (Strings.t("usage.avgActivePerDay", default: "Avg active/day"), "—", nil) }
        return (Strings.t("usage.avgActivePerDay", default: "Avg active/day"),
                usageTimeString(Double(data.activeMinutes * 60 / sessionDays)),
                Strings.t("usage.machineAwake", default: "machine awake"))
    }

    private func statTile(_ label: String, _ value: String,
                          sub: String? = nil, delta: (String, Bool)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1)
                if let delta {
                    HStack(spacing: 1) {
                        Image(systemName: delta.1 ? "arrow.up" : "arrow.down").font(.caption2)
                        Text(delta.0).font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(delta.1 ? Color.green : Color.red)
                }
            }
            Text(sub ?? " ").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.15)))
    }

    // MARK: daily trend (Apple Charts)

    private var trendCard: some View {
        DashCard(title: Strings.t("usage.dailyTrend", default: "Daily Trend"), icon: "chart.bar.fill", tint: .blue) {
            Chart(data.days) { day in
                if let d = day.parsedDate {
                    BarMark(
                        x: .value("Day", d, unit: .day),
                        y: .value("Hours", day.secs / 3600)
                    )
                    .foregroundStyle(day.isToday ? accent.opacity(0.5) : accent)
                    .cornerRadius(3)
                }
            }
            .frame(height: 170)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = value.as(Double.self) { Text(String(format: Strings.t("usage.hours", default: "%dh"), Int(h))) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: xStride)) { value in
                    AxisValueLabel(format: range == .month
                                   ? .dateTime.day()
                                   : .dateTime.weekday(.narrow))
                }
            }
        }
    }

    private var xStride: Int { range == .month ? 4 : 1 }

    // MARK: top apps (proportional bars, click to drill in)

    private var topAppsCard: some View {
        DashCard(title: Strings.t("usage.topApps", default: "Top Apps"), icon: "square.stack.3d.up.fill", tint: .indigo) {
            let top = Array(data.apps.prefix(8))
            let maxSecs = data.apps.first?.secs ?? 1
            // A browser row is always drillable -- even with no sites yet it opens the
            // consent card (Chrome) or the risk note (Safari), so the opt-in is
            // discoverable BEFORE any site is recorded.
            if top.contains(where: { !$0.contexts.isEmpty || isBrowser($0.app) }) {
                Text(Strings.t("usage.clickHint", default: "Click an app (›) to see its sites / projects."))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(top) { app in
                Button { selectedApp = app.app } label: {
                    appBarRow(name: app.app, secs: app.secs, share: app.share,
                              fraction: maxSecs > 0 ? app.secs / maxSecs : 0,
                              showChevron: !app.contexts.isEmpty || isBrowser(app.app))
                }
                .buttonStyle(.plain)
            }
            if data.apps.count > top.count {
                Text(String(format: Strings.t("usage.moreInTable", default: "+ %d more in the table below"), data.apps.count - top.count))
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
    }

    private func appBarRow(name: String, secs: Double, share: Double, fraction: Double,
                           showChevron: Bool = false, muted: Bool = false) -> some View {
        // `muted` (the synthetic "Other / untracked" remainder) reads greyer than a
        // real site/project row, so it's clearly not a place you visited.
        let barTint: Color = muted ? .gray : accent
        return HStack(spacing: 10) {
            Text(name).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
                .foregroundStyle(muted ? Color.gray : Color.primary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(barTint.opacity(0.14))
                    Capsule().fill(barTint).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 7)
            Text(usageTimeString(secs)).font(.caption.monospacedDigit().weight(.medium))
                .frame(width: 56, alignment: .trailing)
            Text(String(format: Strings.t("usage.percent", default: "%d%%"), Int((share * 100).rounded())))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            // Marks rows that drill into a site/project breakdown, so the click
            // affordance is discoverable (esp. a browser -> its domains). Kept in
            // the layout (opacity, not omitted) so bars stay column-aligned.
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)
                .opacity(showChevron ? 1 : 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
    }

    // MARK: app drill-in (its contexts -- domains/projects)

    private func appDrillCard(_ row: UsageAppRow) -> some View {
        DashCard(title: row.app, icon: "chevron.left.circle.fill", tint: .indigo,
                 onTitleTap: { selectedApp = nil }) {
            Text(String(format: Strings.t("usage.ofTrackedTime", default: "%1$@ · %2$d%% of tracked time"),
                        usageTimeString(row.secs), Int((row.share * 100).rounded())))
                .font(.caption).foregroundStyle(.secondary)
            if row.contexts.isEmpty {
                if row.app == "Google Chrome" && !chromeTrackingOn {
                    siteConsentCard                      // safe, one-tap enable (Chrome)
                } else if row.app == "Safari" && !safariTrackingOn {
                    safariRiskNote                       // Settings-only; states the risk, no one-tap
                } else if isBrowser(row.app) {
                    Text(Strings.t("usage.siteRecording",
                                   default: "Recording sites now — they'll appear here as you browse (domain only)."))
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                } else {
                    Text(Strings.t("usage.noBreakdown", default: "No per-site / per-project breakdown for this app."))
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
            } else {
                // Known sites/projects, then an "Other / untracked" remainder so the
                // bars account for the app's WHOLE time. "Other" absorbs incognito
                // (never attributed to a site), untrackable pages (chrome://, new
                // tab), and time recorded before site-tracking was turned on --
                // WITHOUT singling out or labeling private browsing.
                let known = row.contexts.reduce(0.0) { $0 + $1.secs }
                let other = max(0, row.secs - known)
                let showOther = other >= 30      // hide sub-minute rounding dust
                let maxSecs = max(row.contexts.first?.secs ?? 1, showOther ? other : 0)
                ForEach(row.contexts) { c in
                    appBarRow(name: c.name.isEmpty ? "—" : c.name, secs: c.secs,
                              share: c.share, fraction: maxSecs > 0 ? c.secs / maxSecs : 0)
                }
                if showOther {
                    appBarRow(name: Strings.t("usage.otherUntracked", default: "Other / untracked"),
                              secs: other, share: row.secs > 0 ? other / row.secs : 0,
                              fraction: maxSecs > 0 ? other / maxSecs : 0, muted: true)
                }
            }
            Button { selectedApp = nil } label: {
                Label(Strings.t("usage.backToAllApps", default: "Back to all apps"), systemImage: "chevron.left")
            }
            .buttonStyle(.link).font(.caption).padding(.top, 4)
        }
    }

    // MARK: browser-site consent (opt-in, shown in a browser's drill-in)
    //
    // Site/domain collection is off by default; the user must agree before any
    // browsing domain is recorded, per browser. Consent lives HERE -- exactly where
    // the user looks for the per-site detail. Chrome gets a one-tap enable because
    // its incognito is provably excluded at the seam. Safari CANNOT exclude Private
    // Browsing, so it gets no one-tap enable -- only a risk note pointing to
    // Settings, so turning it on is a deliberate, eyes-open choice.

    private func isBrowser(_ app: String) -> Bool {
        app == "Google Chrome" || app == "Safari"
    }

    /// A named usage_stats option (feature id, OptionInfo) if the catalog is loaded.
    private func option(_ key: String) -> (feature: String, opt: OptionInfo)? {
        guard let f = store.features.first(where: { $0.id == "usage_stats" }),
              let o = f.options.first(where: { $0.key == key }) else { return nil }
        return ("usage_stats", o)
    }

    private func trackingOn(_ key: String) -> Bool {
        guard let s = option(key) else { return false }
        return (store.optionValue(s.feature, s.opt) as? Bool) ?? false
    }

    private var chromeTrackingOn: Bool { trackingOn("trackChromeSite") }
    private var safariTrackingOn: Bool { trackingOn("trackSafariSite") }

    private var siteConsentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.t("usage.siteConsentTitle", default: "Chrome site details are off"))
                .font(.callout.weight(.medium))
            Text(Strings.t("usage.siteConsentBody",
                           default: "Turn on to record which sites you visit in Chrome — the domain only (e.g. github.com), never the full URL or page, and never incognito windows. You can turn it off anytime."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let s = option("trackChromeSite") {
                    store.setOptionValue(s.feature, s.opt, true)
                    load(reset: false)
                }
            } label: {
                Label(Strings.t("usage.enableSiteDetails", default: "Turn on Chrome site details"),
                      systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .disabled(option("trackChromeSite") == nil)
        }
        .padding(.top, 4)
    }

    /// Safari's drill-in when its tracking is off: unlike Chrome, no one-tap enable
    /// -- Safari can't hide Private Browsing, so we state the risk and route the
    /// opt-in through Settings, where the same warning is on the toggle itself.
    private var safariRiskNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.t("usage.safariOffTitle", default: "Safari sites aren't recorded"))
                .font(.callout.weight(.medium))
            Text(Strings.t("usage.safariOffBody",
                           default: "Unlike Chrome, Safari gives us no way to tell a Private Browsing window apart, so a private site could be recorded. If you accept that, turn on “Also record Safari sites” in Settings › Usage Stats."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: full ranked table

    private var detailTableCard: some View {
        DashCard(title: Strings.t("usage.allApps", default: "All Apps"), icon: "list.bullet", tint: .gray) {
            HStack {
                Text(Strings.t("usage.app", default: "APP")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(Strings.t("usage.time", default: "TIME")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                Text(Strings.t("usage.share", default: "SHARE")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 10, height: 1)   // aligns with the row chevron
            }
            Divider().opacity(0.4)
            ForEach(data.apps) { app in
                Button { selectedApp = app.app } label: {
                    HStack {
                        Text(app.app).font(.callout).lineLimit(1)
                        Spacer()
                        Text(usageTimeString(app.secs)).font(.caption.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                        Text(String(format: Strings.t("usage.percent", default: "%d%%"), Int((app.share * 100).rounded())))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(width: 10, alignment: .trailing)
                            .opacity(app.contexts.isEmpty && !isBrowser(app.app) ? 0 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: daily rhythm (machine-active sessions)

    @ViewBuilder private var rhythmCard: some View {
        if !data.sessions.isEmpty {
            let days = groupedByDay(data.sessions)
            DashCard(title: Strings.t("usage.dailyRhythm", default: "Daily Rhythm"), icon: "clock.fill", tint: .teal) {
                let sessionsStr = String(format: Strings.plural("usage.sessions", data.sessionCount,
                                                                one: "%d session", other: "%d sessions"),
                                         data.sessionCount)
                let daysStr = String(format: Strings.plural("usage.days", days.count,
                                                            one: "%d day", other: "%d days"),
                                     days.count)
                let longestStr = usageTimeString(Double(data.longestSessionMin * 60))
                Text(String(format: Strings.t("usage.rhythmCaption",
                                              default: "When the machine was awake, by day. %1$@ across %2$@; longest %3$@."),
                            sessionsStr, daysStr, longestStr))
                    .font(.caption).foregroundStyle(.secondary)
                // 0–24h scale, shown once and aligned to the track column.
                HStack(spacing: 10) {
                    Spacer(minLength: 0).frame(width: 84)
                    hourAxis
                    Spacer(minLength: 0).frame(width: 56)
                }
                .padding(.top, 2)
                ForEach(days, id: \.date) { day in
                    HStack(spacing: 10) {
                        Text(day.date).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: 84, alignment: .leading)
                        dayTrack(day.sessions)
                        Text(usageTimeString(day.totalMin * 60))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Collapse the flat session list to one entry per day (preserving the day
    /// order report.lua emits), summing each day's awake minutes for the total.
    private func groupedByDay(_ sessions: [UsageSession])
        -> [(date: String, sessions: [UsageSession], totalMin: Double)] {
        var order: [String] = []
        var byDay: [String: [UsageSession]] = [:]
        for s in sessions {
            if byDay[s.date] == nil { order.append(s.date) }
            byDay[s.date, default: []].append(s)
        }
        return order.map { d in
            let ss = byDay[d] ?? []
            return (date: d, sessions: ss, totalMin: ss.reduce(0) { $0 + $1.minutes })
        }
    }

    /// A compact 00–24h scale; each label is CENTERED on its quarter-day gridline
    /// (the ends nudged just inside the track so "00"/"24" don't clip), so the
    /// axis shares one coordinate system with the gridlines and bands below.
    private var hourAxis: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ForEach(0...4, id: \.self) { i in
                Text(i == 0 ? "00" : (i == 4 ? "24" : String(format: "%02d", i * 6)))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: min(max(w * (Double(i) / 4), 7), w - 7), y: 5)
            }
        }
        .frame(height: 10)
    }

    /// One day's 24h track: faint quarter-day gridlines + every session for that
    /// day drawn as a teal band positioned by wake->sleep time. A session that
    /// crosses midnight (sleepMin < wakeMin) clamps to the day's edge.
    private func dayTrack(_ sessions: [UsageSession]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.12))
                ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                    Rectangle().fill(Color.gray.opacity(0.18))
                        .frame(width: 1).offset(x: w * f)
                }
                ForEach(sessions) { s in
                    if let wm = s.wakeMin, let sl = s.sleepMin {
                        // sl < wm means the span crossed midnight (clamp to the
                        // day's edge) -- but only when the gap is real; a small
                        // backward step (clock skew / truncated seconds) collapses
                        // to a sliver instead of a bogus full-evening band.
                        let end = sl >= wm ? sl : (wm - sl > 720 ? 1440 : sl)
                        Capsule().fill(Color.teal.opacity(0.75))
                            .frame(width: max(3, w * ((end - wm) / 1440)))
                            .offset(x: w * (wm / 1440))
                    }
                }
            }
            .clipShape(Capsule())   // keep min-width bands from poking past the track edge
        }
        .frame(height: 9)
    }

    // MARK: empty state

    private var emptyCard: some View {
        let usage = store.features.first { $0.id == "usage_stats" }
        return DashCard(title: Strings.t("usage.noUsageYet", default: "No usage yet"), icon: "chart.bar.xaxis", tint: .blue) {
            Text(Strings.t("usage.emptyBody", default: "Usage Stats records per-app focus time as you work. Once there's a day on disk, this report fills in."))
                .font(.callout).foregroundStyle(.secondary)
            if let usage, !usage.enabled {
                Button { store.requestSetEnabled("usage_stats", true); load() } label: {
                    Label(Strings.t("usage.enableUsageStats", default: "Enable Usage Stats"), systemImage: "power")
                }
                .buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
    }
}
