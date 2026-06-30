import Foundation

// Typed models for the Usage report -- the host-side mirror of what
// features.usage_stats.report.range() returns over the bridge (numbers arrive
// as Double; see LuaState.any). The Lua side computes, Swift renders.

struct UsageContextRow: Identifiable {
    let name: String
    let secs: Double
    let share: Double      // within its app (0..1)
    var id: String { name }
}

struct UsageAppRow: Identifiable {
    let app: String
    let secs: Double
    let share: Double      // of the range total (0..1)
    let contexts: [UsageContextRow]
    var id: String { app }
}

struct UsageDay: Identifiable {
    let date: String       // yyyy-MM-dd
    let label: String      // weekday letter
    let secs: Double
    let isToday: Bool
    var id: String { date }
}

struct UsageSession: Identifiable {
    let date: String
    let minutes: Double
    let wakeMin: Double?    // minutes since midnight
    let sleepMin: Double?
    let id = UUID()
}

/// The whole report for a date range. Non-failable: a missing/garbled field
/// degrades to an empty/zero value so the view can always render (the empty
/// state handles "no data").
struct UsageReportData {
    let total: Double
    let activeDays: Int
    let dailyAvg: Double
    let prevTotal: Double
    let prevHasData: Bool
    let days: [UsageDay]
    let apps: [UsageAppRow]
    let sessions: [UsageSession]
    let busiestApp: String?
    let firstWakeMin: Int?
    let lastSleepMin: Int?
    let sessionCount: Int
    let longestSessionMin: Int
    let activeMinutes: Int

    static let empty = UsageReportData([:])

    var hasData: Bool { total > 0 || !apps.isEmpty }

    init(_ d: [String: Any]) {
        func num(_ k: String) -> Double { d[k] as? Double ?? 0 }
        total = num("total")
        activeDays = Int(num("activeDays"))
        dailyAvg = num("dailyAvg")
        prevTotal = num("prevTotal")
        prevHasData = d["prevHasData"] as? Bool ?? false
        days = ((d["days"] as? [Any]) ?? []).compactMap { e in
            guard let r = e as? [String: Any], let date = r["date"] as? String else { return nil }
            return UsageDay(date: date, label: r["label"] as? String ?? "",
                            secs: r["secs"] as? Double ?? 0,
                            isToday: r["today"] as? Bool ?? false)
        }
        apps = ((d["apps"] as? [Any]) ?? []).compactMap { e in
            guard let r = e as? [String: Any], let app = r["app"] as? String else { return nil }
            let ctx = ((r["contexts"] as? [Any]) ?? []).compactMap { c -> UsageContextRow? in
                guard let cr = c as? [String: Any], let n = cr["name"] as? String else { return nil }
                return UsageContextRow(name: n, secs: cr["secs"] as? Double ?? 0,
                                       share: cr["share"] as? Double ?? 0)
            }
            return UsageAppRow(app: app, secs: r["secs"] as? Double ?? 0,
                               share: r["share"] as? Double ?? 0, contexts: ctx)
        }
        sessions = ((d["sessions"] as? [Any]) ?? []).compactMap { e in
            guard let r = e as? [String: Any], let date = r["date"] as? String else { return nil }
            return UsageSession(date: date,
                                minutes: r["min"] as? Double ?? 0,
                                wakeMin: r["wakeMin"] as? Double, sleepMin: r["sleepMin"] as? Double)
        }
        busiestApp = d["busiestApp"] as? String
        firstWakeMin = (d["firstWakeMin"] as? Double).map(Int.init)
        lastSleepMin = (d["lastSleepMin"] as? Double).map(Int.init)
        sessionCount = Int(num("sessionCount"))
        longestSessionMin = Int(num("longestSessionMin"))
        activeMinutes = Int(num("activeMinutes"))
    }
}

// MARK: - Range selection

/// The report's time window. Today/Week/Month are trailing windows (Month =
/// trailing 30 days -- robust to partial calendar months); Custom is an explicit
/// span. `periodsBack` steps the window backward by whole periods (0 = current).
enum ReportRange: String, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    /// Number of days the window spans.
    var span: Int {
        switch self {
        case .today: return 1
        case .week:  return 7
        case .month: return 30
        }
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// Inclusive [from, to] dates for the window stepped `periodsBack` whole
    /// periods before today. Days are computed in the current calendar.
    func bounds(periodsBack: Int, now: Date = Date()) -> (from: Date, to: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let to = cal.date(byAdding: .day, value: -periodsBack * span, to: today) ?? today
        let from = cal.date(byAdding: .day, value: -(span - 1), to: to) ?? to
        return (from, to)
    }

    func isoBounds(periodsBack: Int, now: Date = Date()) -> (from: String, to: String) {
        let b = bounds(periodsBack: periodsBack, now: now)
        return (Self.iso.string(from: b.from), Self.iso.string(from: b.to))
    }

    /// Header label for the current window, e.g. "Today", "Jun 18 – 24".
    func label(periodsBack: Int, now: Date = Date()) -> String {
        let b = bounds(periodsBack: periodsBack, now: now)
        if span == 1 {
            return periodsBack == 0 ? "Today" : Self.display.string(from: b.to)
        }
        return Self.display.string(from: b.from) + " – " + Self.display.string(from: b.to)
    }
}

private let usageDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

extension UsageDay {
    /// The day as a Date (local midnight), for Charts' temporal x-axis. nil only
    /// if the date string is malformed.
    var parsedDate: Date? { usageDayParser.date(from: date) }
}

/// "9:00 AM"-style label for a minutes-since-midnight value (session rhythm).
func clockLabel(_ minutesOfDay: Int) -> String {
    let m = ((minutesOfDay % 1440) + 1440) % 1440
    let h24 = m / 60, mm = m % 60
    let h12 = h24 % 12 == 0 ? 12 : h24 % 12
    return String(format: "%d:%02d %@", h12, mm, h24 < 12 ? "AM" : "PM")
}
