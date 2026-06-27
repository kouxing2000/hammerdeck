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
        // Reloads on first appear and whenever the window changes; selecting an
        // app does NOT change this id, so a drill-in never refetches.
        .task(id: "\(range.rawValue)|\(periodsBack)") { load() }
    }

    // MARK: data

    private func load() {
        selectedApp = nil
        let b = range.isoBounds(periodsBack: periodsBack)
        if let raw = store.readerCall("features.usage_stats.report", "range",
                                      [.string(b.from), .string(b.to)]) as? [String: Any] {
            data = UsageReportData(raw)
        } else {
            data = .empty
        }
    }

    // MARK: header (title + range switcher + stepper)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage").font(.title2.weight(.semibold))
                Text(range.label(periodsBack: periodsBack))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            HStack(spacing: 4) {
                Button { periodsBack += 1 } label: { Image(systemName: "chevron.left") }
                    .help("Earlier")
                Button { if periodsBack > 0 { periodsBack -= 1 } } label: { Image(systemName: "chevron.right") }
                    .disabled(periodsBack == 0)
                    .help("Later")
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
            statTile("Total active", usageTimeString(data.total), delta: totalDelta)
            statTile("Daily avg", usageTimeString(data.dailyAvg),
                     sub: "\(data.activeDays) active \(data.activeDays == 1 ? "day" : "days")")
            statTile("Busiest app", data.busiestApp ?? "—",
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
                return ("Active hours", "—", nil)
            }
            return ("Active hours", usageTimeString(Double((s - w) * 60)),
                    "\(clockLabel(w)) – \(clockLabel(s))")
        }
        let sessionDays = Set(data.sessions.map(\.date)).count
        guard sessionDays > 0, data.activeMinutes > 0 else { return ("Avg active/day", "—", nil) }
        return ("Avg active/day",
                usageTimeString(Double(data.activeMinutes * 60 / sessionDays)),
                "machine awake")
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
        DashCard(title: "Daily Trend", icon: "chart.bar.fill", tint: .blue) {
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
                        if let h = value.as(Double.self) { Text("\(Int(h))h") }
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
        DashCard(title: "Top Apps", icon: "square.stack.3d.up.fill", tint: .indigo) {
            let top = Array(data.apps.prefix(8))
            let maxSecs = data.apps.first?.secs ?? 1
            ForEach(top) { app in
                Button { selectedApp = app.app } label: {
                    appBarRow(name: app.app, secs: app.secs, share: app.share,
                              fraction: maxSecs > 0 ? app.secs / maxSecs : 0)
                }
                .buttonStyle(.plain)
            }
            if data.apps.count > top.count {
                Text("+ \(data.apps.count - top.count) more in the table below")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
    }

    private func appBarRow(name: String, secs: Double, share: Double, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.callout).lineLimit(1).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.14))
                    Capsule().fill(accent).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 7)
            Text(usageTimeString(secs)).font(.caption.monospacedDigit().weight(.medium))
                .frame(width: 56, alignment: .trailing)
            Text("\(Int((share * 100).rounded()))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
    }

    // MARK: app drill-in (its contexts -- domains/projects)

    private func appDrillCard(_ row: UsageAppRow) -> some View {
        DashCard(title: row.app, icon: "chevron.left.circle.fill", tint: .indigo,
                 onTitleTap: { selectedApp = nil }) {
            Text("\(usageTimeString(row.secs)) · \(Int((row.share * 100).rounded()))% of tracked time")
                .font(.caption).foregroundStyle(.secondary)
            if row.contexts.isEmpty {
                Text("No per-site / per-project breakdown for this app.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                let maxSecs = row.contexts.first?.secs ?? 1
                ForEach(row.contexts) { c in
                    appBarRow(name: c.name.isEmpty ? "—" : c.name, secs: c.secs,
                              share: c.share, fraction: maxSecs > 0 ? c.secs / maxSecs : 0)
                }
            }
            Button { selectedApp = nil } label: {
                Label("Back to all apps", systemImage: "chevron.left")
            }
            .buttonStyle(.link).font(.caption).padding(.top, 4)
        }
    }

    // MARK: full ranked table

    private var detailTableCard: some View {
        DashCard(title: "All Apps", icon: "list.bullet", tint: .gray) {
            HStack {
                Text("APP").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("TIME").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                Text("SHARE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Divider().opacity(0.4)
            ForEach(data.apps) { app in
                Button { selectedApp = app.app } label: {
                    HStack {
                        Text(app.app).font(.callout).lineLimit(1)
                        Spacer()
                        Text(usageTimeString(app.secs)).font(.caption.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                        Text("\(Int((app.share * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
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
            DashCard(title: "Daily Rhythm", icon: "clock.fill", tint: .teal) {
                Text("When the machine was awake, by day. \(data.sessionCount) "
                     + "\(data.sessionCount == 1 ? "session" : "sessions") across \(days.count) "
                     + "\(days.count == 1 ? "day" : "days"); longest "
                     + usageTimeString(Double(data.longestSessionMin * 60)) + ".")
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
        return DashCard(title: "No usage yet", icon: "chart.bar.xaxis", tint: .blue) {
            Text("Usage Stats records per-app focus time as you work. "
                 + "Once there's a day on disk, this report fills in.")
                .font(.callout).foregroundStyle(.secondary)
            if let usage, !usage.enabled {
                Button { store.requestSetEnabled("usage_stats", true); load() } label: {
                    Label("Enable Usage Stats", systemImage: "power")
                }
                .buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
    }
}
