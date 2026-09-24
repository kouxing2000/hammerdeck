import SwiftUI
import AppKit
import Combine

// The Automation Timeline: the TIME-dimension sibling of the Shortcut Map. The
// Shortcut Map answers "what does each KEY do"; this answers "what fires WHEN".
// It plots every time/event automation on a 24h ruler (Day view) or a sorted
// "what's next" list (Agenda view), so the user can see what the app does in
// the background, spot two things stacked at the same minute, and edit a
// schedule without drilling into each feature.
//
// Two data sources feed it, both from registry.describe() (no new bridge call):
//   1. ACTION triggers whose type is `schedule` (at / everyMin) or `event` --
//      edited the same way the Shortcut Map edits hotkeys: store.setTrigger.
//   2. A service's self-reported `schedule` descriptor entries -- a service runs
//      its own internal timers (sleep warnings, the break interval) that the
//      trigger model never sees; the descriptor surfaces them. Entries that name
//      an `optionKey` are edited by writing that option (store.setOptionValue),
//      the same path the Settings form uses; derived ones (e.g. a warning offset)
//      are advisory and read-only here.
//
// A THIRD source: automation RULES (the Rules page) -- cross-feature
// automations that also live on the time axis. Their schedule/event triggers map
// to the same markers; their `state` triggers (frontmostApp becomes X) land in
// the conditions lane. Rules are READ-ONLY here (edited in the Rules page) and
// tagged with a wand glyph; their featureId sentinel is `__rules__`.
//
// Hotkey/chord actions (and hotkey/chord rules) have NO place on the time axis
// and are excluded -- they live in the Shortcut Map. The views partition cleanly.

// MARK: - Aggregated item model

private enum TLKind {
    case at(Int)            // minutes since midnight (a daily marker)
    case everyMin(Int)      // a repeating interval (a labelled lane)
    case event(String)      // a system event (events lane)
    case note(String)       // a non-time condition, e.g. "after 5m idle"
}

private struct TLItem: Identifiable {
    let id: String
    let featureId: String
    let featureName: String
    let label: String
    let kind: TLKind
    let category: String
    let enabled: Bool

    // Editing route -- at most one is set:
    let actionId: String?   // a real action trigger: edit via store.setTrigger
    let optionKey: String?  // a descriptor entry bound to an option: edit via store.setOptionValue
    let optionType: String? // "time" | "int" (drives the editor shape)

    var editable: Bool { actionId != nil || optionKey != nil }

    // A rule (Rules page) vs a feature automation -- drives the wand glyph. Rules
    // use the `__rules__` featureId sentinel; clicking one deep-links to its editor.
    var isRule: Bool { featureId == "__rules__" }

    /// The marker tint. A rule is not a feature and has no category, so it gets
    /// the purple its own legend entry (the wand) already uses, rather than
    /// borrowing a feature category for the color -- which is what this did until
    /// 2026-07-28, when the borrowed name was retired from the vocabulary and every
    /// rule marker silently fell through categoryColor's default to gray.
    var tint: Color { isRule ? .purple : categoryColor(category) }

    // The rule's id when this item is a rule (parsed from the `id` sentinel
    // "rule|<id>", 5-char prefix), else nil -- the deep-link target.
    var ruleId: String? { isRule ? String(id.dropFirst(5)) : nil }

    var minutesOfDay: Int? {
        if case let .at(m) = kind { return m }
        return nil
    }
}

// categoryColor lives in FeatureChrome.swift (shared with the Shortcut Map and
// Feature Gallery).

private func fmtHM(_ minutes: Int) -> String {
    let m = ((minutes % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}

private func fmtEvery(_ min: Int) -> String {
    if min % 60 == 0 { return String(format: Strings.t("timeline.everyH", default: "every %dh"), min / 60) }
    if min > 60 { return String(format: Strings.t("timeline.everyHM", default: "every %1$dh%2$dm"), min / 60, min % 60) }
    return String(format: Strings.t("timeline.everyM", default: "every %dm"), min)
}

// MARK: - The view

struct AutomationTimelineView: View {
    @ObservedObject var store: SettingsStore
    @State private var mode = 0            // 0 = Day, 1 = Agenda
    @State private var showDisabled = false
    @State private var nowMinutes = AutomationTimelineView.currentMinutes()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    static func currentMinutes() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if mode == 0 { DayView(items: items, nowMinutes: nowMinutes, store: store) }
            else { AgendaView(items: items, nowMinutes: nowMinutes, store: store) }
            Divider()
            legend
        }
        // Embedded in the Homepage shell, which owns the window minimum size.
        .onAppear { store.refresh(); store.refreshRules() }
        .onReceive(tick) { _ in nowMinutes = Self.currentMinutes() }
    }

    private var toolbar: some View {
        HStack {
            Text(Strings.t("timeline.title", default: "Automation Timeline")).font(.headline)
            Spacer()
            Picker("", selection: $mode) {
                Text(Strings.t("timeline.day", default: "Day")).tag(0)
                Text(Strings.t("timeline.agenda", default: "Agenda")).tag(1)
            }
            .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            Toggle(Strings.t("timeline.showDisabled", default: "Show disabled"), isOn: $showDisabled)
                .toggleStyle(.checkbox).font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The category dots to explain -- DERIVED from what is actually on the axis,
    /// in canonical order. It used to be a hardcoded four-name list, which is a
    /// fourth copy of the category vocabulary and drifted the moment that
    /// vocabulary was re-cut: it went on advertising two retired names (as gray
    /// dots, since categoryColor no longer knew them) while every category that
    /// had reached the timeline went unlabelled. Deriving it deletes that copy
    /// rather than updating it, so the drift cannot recur.
    private var legendCategories: [String] {
        Array(Set(items.filter { !$0.isRule }.map(\.category))).sorted {
            (categoryRank($0), $0) < (categoryRank($1), $1)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(legendCategories, id: \.self) { c in
                HStack(spacing: 4) {
                    Circle().fill(categoryColor(c)).frame(width: 7, height: 7)
                    Text(categoryLabel(c)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.purple)
                Text(Strings.t("timeline.rule", default: "rule")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Strings.t("timeline.legendHint", default: "Click a feature marker to edit its time; click a rule to open it in the Rules page."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: aggregation

    private var items: [TLItem] {
        var out: [TLItem] = []
        for f in store.features where !f.failed && (f.enabled || showDisabled) {
            // 1. action triggers that live on the time axis
            for a in f.actions {
                guard let t = a.trigger else { continue }
                if t.type == "schedule" {
                    let kind: TLKind? = t.everyMin.map { .everyMin($0) }
                        ?? t.at.flatMap(Self.minutesOf).map { .at($0) }
                    if let kind {
                        out.append(TLItem(id: "\(f.id)|\(a.id)|trig", featureId: f.id,
                                          featureName: f.name,
                                          label: f.actions.count > 1 ? a.label : f.name,
                                          kind: kind, category: f.category, enabled: f.enabled,
                                          actionId: a.id, optionKey: nil, optionType: nil))
                    }
                } else if t.type == "event", let ev = t.event {
                    out.append(TLItem(id: "\(f.id)|\(a.id)|ev", featureId: f.id,
                                      featureName: f.name,
                                      label: f.actions.count > 1 ? a.label : f.name,
                                      kind: .event(ev), category: f.category, enabled: f.enabled,
                                      actionId: a.id, optionKey: nil, optionType: nil))
                }
            }
            // 2. service-declared schedule descriptor entries
            for e in f.schedule {
                let kind: TLKind
                switch e.kind {
                case "everyMin": kind = .everyMin(e.everyMin ?? 0)
                case "at":       guard let m = e.minutesOfDay else { continue }; kind = .at(m)
                case "event":    kind = .event(e.event ?? "")
                default:         kind = .note(e.note ?? e.label)
                }
                let optType = e.optionKey.flatMap { key in
                    f.options.first { $0.key == key }?.type
                }
                out.append(TLItem(id: "\(f.id)|\(e.id)|desc", featureId: f.id,
                                  featureName: f.name, label: e.label, kind: kind,
                                  category: e.category, enabled: f.enabled,
                                  actionId: nil, optionKey: e.optionKey, optionType: optType))
            }
        }
        // 3. automation rules (the Rules page) -- read-only on the timeline.
        for r in store.rules where r.enabled || showDisabled {
            guard let kind = Self.ruleKind(r.on) else { continue }   // hotkey/chord/malformed -> off-axis
            out.append(TLItem(id: "rule|\(r.id)", featureId: "__rules__",
                              featureName: String(format: Strings.t("timeline.ruleName", default: "Rule -- %@"), r.triggerDesc),
                              label: r.effectDesc, kind: kind,
                              // Tint comes from `isRule` (see TLItem.tint); a rule is not
                              // a feature, so this is only the neutral fallback.
                              category: "general", enabled: r.enabled,
                              actionId: nil, optionKey: nil, optionType: nil))
        }
        return out
    }

    // Map a rule's raw `on` trigger spec to a timeline kind, or nil when it has
    // no place on the time axis (hotkey/chord/unknown). Numbers may arrive as Int
    // or Double across the bridge, so both are accepted.
    private static func ruleKind(_ on: [String: Any]) -> TLKind? {
        switch on["type"] as? String {
        case "schedule":
            if let n = (on["everyMin"] as? Int) ?? (on["everyMin"] as? Double).map(Int.init) {
                return .everyMin(n)
            }
            if let at = on["at"] as? String, let m = minutesOf(at) { return .at(m) }
            return nil
        case "event":
            return .event(on["event"] as? String ?? "")
        case "state":
            let sig = on["signal"] as? String ?? "state"
            let verb = on["becomes"] != nil ? Strings.t("timeline.becomes", default: "becomes") : Strings.t("timeline.leaves", default: "leaves")
            let val = (on["becomes"] as? String) ?? (on["leaves"] as? String) ?? ""
            return .note("\(sig) \(verb) \(val)")
        default:
            return nil
        }
    }

    static func minutesOf(_ hhmm: String) -> Int? { HHMM.minutesOfDay(hhmm) }
}

// MARK: - Day view (24h ruler + lanes)

private struct DayView: View {
    let items: [TLItem]
    let nowMinutes: Int
    @ObservedObject var store: SettingsStore

    private let hourHeight: CGFloat = 46
    private var rulerHeight: CGFloat { hourHeight * 24 }

    private var atItems: [TLItem] {
        items.filter { $0.minutesOfDay != nil }
            .sorted { ($0.minutesOfDay ?? 0) < ($1.minutesOfDay ?? 0) }
    }
    private var recurring: [TLItem] {
        items.filter { if case .everyMin = $0.kind { return true }; return false }
    }
    private var conditions: [TLItem] {
        items.filter {
            switch $0.kind { case .event, .note: return true; default: return false }
        }
    }

    // minute -> how many daily markers land there (the "stacked" advisory)
    private var stackCounts: [Int: Int] {
        Dictionary(grouping: atItems.compactMap { $0.minutesOfDay }, by: { $0 })
            .mapValues { $0.count }
    }

    // the next daily marker at/after now (wrapping past midnight); highlighted
    private var nextMinute: Int? {
        let mins = atItems.filter { $0.enabled }.compactMap { $0.minutesOfDay }
        guard !mins.isEmpty else { return nil }
        return mins.first { $0 >= nowMinutes } ?? mins.min()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { ruler.padding(.vertical, 8) }
                .frame(minWidth: 360)
            Divider()
            sidePanel.frame(width: 280)
        }
    }

    private var ruler: some View {
        ZStack(alignment: .topLeading) {
            // hour grid + labels
            ForEach(0..<25) { h in
                let y = CGFloat(h) * hourHeight
                Text(h < 24 ? String(format: "%02d:00", h) : "")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .offset(x: 0, y: y - 6)
                Rectangle().fill(.quaternary).frame(height: 1)
                    .padding(.leading, 50).offset(y: y)
            }
            // markers
            ForEach(atItems) { item in
                if let m = item.minutesOfDay {
                    DayMarker(item: item,
                              stacked: (stackCounts[m] ?? 0) > 1,
                              isNext: m == nextMinute && item.enabled,
                              store: store)
                        .offset(x: 54, y: CGFloat(m) / 60 * hourHeight - 11)
                }
            }
            // now line
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.red).frame(height: 1.5)
                Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: -2)
            }
            .padding(.leading, 48)
            .offset(y: CGFloat(nowMinutes) / 60 * hourHeight)
        }
        .frame(height: rulerHeight, alignment: .topLeading)
        .padding(.horizontal, 10)
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                laneSection(Strings.t("timeline.recurring", default: "RECURRING"), recurring,
                            empty: Strings.t("timeline.emptyRecurring", default: "No repeating intervals"))
                Divider().padding(.vertical, 4)
                laneSection(Strings.t("timeline.eventsConditions", default: "EVENTS & CONDITIONS"), conditions,
                            empty: Strings.t("timeline.emptyConditions", default: "No event-driven actions"))
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func laneSection(_ title: String, _ rows: [TLItem], empty: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.bottom, 6)
        if rows.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.tertiary).padding(.bottom, 4)
        } else {
            ForEach(rows) { LaneChip(item: $0, store: store) }
        }
    }
}

// MARK: - A daily marker on the ruler (click to edit)

private struct DayMarker: View {
    let item: TLItem
    let stacked: Bool
    let isNext: Bool
    @ObservedObject var store: SettingsStore
    @State private var editing = false

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 5) {
                Circle().fill(item.tint.opacity(item.enabled ? 1 : 0.4))
                    .frame(width: 8, height: 8)
                Text(fmtHM(item.minutesOfDay ?? 0))
                    .font(.caption.monospacedDigit().weight(.medium))
                Text(item.label).font(.caption).lineLimit(1)
                if item.isRule {
                    Image(systemName: "wand.and.stars").font(.system(size: 8))
                        .foregroundStyle(.purple).help(Strings.t("timeline.ruleMarkerHelp", default: "Automation rule -- click to open in the Rules page"))
                }
                if stacked {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                        .help(Strings.t("timeline.stackedHelp", default: "Another automation fires this same minute"))
                }
                if item.editable {
                    Image(systemName: "pencil").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(isNext ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isNext ? Color.accentColor : .secondary.opacity(0.2),
                        lineWidth: isNext ? 1.2 : 0.8))
            .opacity(item.enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .help(item.enabled ? item.featureName : String(format: Strings.t("timeline.disabledSuffix", default: "%@ (disabled)"), item.featureName))
        .popover(isPresented: $editing) { EditPopover(item: item, store: store) }
    }

    // A feature marker opens its inline time editor; a rule deep-links to the
    // Rules page (the shell switches tabs and selects it for editing).
    private func open() {
        if item.editable { editing = true }
        else if let rid = item.ruleId { store.selectedRuleId = rid }
    }
}

// MARK: - A non-time lane chip (recurring / event / condition)

private struct LaneChip: View {
    let item: TLItem
    @ObservedObject var store: SettingsStore
    @State private var editing = false

    private var detail: String {
        switch item.kind {
        case .everyMin(let m): return fmtEvery(m)
        case .event(let e):    return String(format: Strings.t("timeline.onEvent", default: "on %@"), e)
        case .note(let n):     return n
        case .at:              return ""
        }
    }
    private var icon: String {
        switch item.kind {
        case .everyMin: return "repeat"
        case .event:    return "bolt"
        case .note:     return "moon.zzz"
        case .at:       return "clock"
        }
    }

    var body: some View {
        Button { open() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2)
                    .foregroundStyle(item.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label).font(.caption).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if item.isRule {
                    Image(systemName: "wand.and.stars").font(.system(size: 9))
                        .foregroundStyle(.purple)
                        .help(Strings.t("timeline.ruleMarkerHelp", default: "Automation rule -- click to open in the Rules page"))
                }
                if item.editable {
                    Image(systemName: "pencil").font(.system(size: 8)).foregroundStyle(.secondary)
                } else if item.isRule {
                    // a clickable affordance for rules (which have no inline editor)
                    Image(systemName: "chevron.right").font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
            .opacity(item.enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help(item.enabled ? item.featureName : String(format: Strings.t("timeline.disabledSuffix", default: "%@ (disabled)"), item.featureName))
        .popover(isPresented: $editing) { EditPopover(item: item, store: store) }
    }

    // A feature chip opens its inline editor; a rule deep-links to the Rules page.
    private func open() {
        if item.editable { editing = true }
        else if let rid = item.ruleId { store.selectedRuleId = rid }
    }
}

// MARK: - Agenda view (sorted "what fires next")

private struct AgendaView: View {
    let items: [TLItem]
    let nowMinutes: Int
    @ObservedObject var store: SettingsStore

    // daily markers sorted by time-until-next-fire (wrapping past midnight),
    // then the recurring / event / condition rows.
    private var timed: [TLItem] {
        items.filter { $0.minutesOfDay != nil }
            .sorted { untilNext($0) < untilNext($1) }
    }
    private var others: [TLItem] {
        items.filter { $0.minutesOfDay == nil }
    }

    private func untilNext(_ item: TLItem) -> Int {
        guard let m = item.minutesOfDay else { return Int.max }
        let d = m - nowMinutes
        return d >= 0 ? d : d + 1440
    }

    private func relative(_ mins: Int) -> String {
        if mins == 0 { return Strings.t("timeline.now", default: "now") }
        if mins < 60 { return String(format: Strings.t("timeline.inMin", default: "in %d min"), mins) }
        return String(format: Strings.t("timeline.inHM", default: "in %1$dh %2$dm"), mins / 60, mins % 60)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(timed) { item in
                    AgendaRow(item: item,
                              lead: fmtHM(item.minutesOfDay ?? 0),
                              trail: relative(untilNext(item)), store: store)
                    Divider()
                }
                if !others.isEmpty {
                    HStack {
                        Text(Strings.t("timeline.recurringEventDriven", default: "RECURRING & EVENT-DRIVEN"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                    ForEach(others) { item in
                        AgendaRow(item: item, lead: leadFor(item), trail: "", store: store)
                        Divider()
                    }
                }
                if timed.isEmpty && others.isEmpty {
                    Text(Strings.t("timeline.empty", default: "Nothing scheduled. Bind an action to a schedule, or enable a time-based feature."))
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(40)
                }
            }
        }
    }

    private func leadFor(_ item: TLItem) -> String {
        switch item.kind {
        case .everyMin(let m): return fmtEvery(m)
        case .event:           return Strings.t("timeline.leadEvent", default: "event")
        case .note:            return Strings.t("timeline.leadIdle", default: "idle")
        case .at:              return ""
        }
    }
}

private struct AgendaRow: View {
    let item: TLItem
    let lead: String
    let trail: String
    @ObservedObject var store: SettingsStore
    @State private var editing = false

    private var detail: String {
        switch item.kind {
        case .event(let e): return String(format: Strings.t("timeline.onEvent", default: "on %@"), e)
        case .note(let n):  return n
        default:            return ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(item.tint.opacity(item.enabled ? 1 : 0.4))
                .frame(width: 8, height: 8)
            Text(lead).font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let rid = item.ruleId {
                Button { store.selectedRuleId = rid } label: {
                    Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(.purple)
                }
                .buttonStyle(.plain)
                .help(Strings.t("timeline.openRuleHelp", default: "Open this rule in the Rules page"))
            }
            if !trail.isEmpty {
                Text(trail).font(.caption).foregroundStyle(.secondary)
            }
            if !item.enabled {
                Text(Strings.t("timeline.disabledLabel", default: "disabled")).font(.caption2).foregroundStyle(.tertiary)
            }
            if item.editable {
                Button { editing = true } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $editing) { EditPopover(item: item, store: store) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .opacity(item.enabled ? 1 : 0.6)
    }
}

// MARK: - Edit popover (time / interval)

private struct EditPopover: View {
    let item: TLItem
    @ObservedObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var error: String?

    private var isTime: Bool {
        if case .at = item.kind { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.label).font(.headline)
            Text(item.featureName).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(isTime ? Strings.t("timeline.timeLabel", default: "Time (HH:MM)")
                            : Strings.t("timeline.everyLabel", default: "Every (minutes)")).font(.callout)
                TextField(isTime ? "HH:MM" : Strings.t("timeline.minutesPlaceholder", default: "minutes"), text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit(save)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(Strings.t("timeline.cancel", default: "Cancel")) { dismiss() }
                Button(Strings.t("timeline.save", default: "Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 240)
        .onAppear { text = initialText }
    }

    private var initialText: String {
        switch item.kind {
        case .at(let m):       return fmtHM(m)
        case .everyMin(let n): return String(n)
        default:               return ""
        }
    }

    private func save() {
        if isTime {
            guard let m = AutomationTimelineView.minutesOf(text.trimmingCharacters(in: .whitespaces)),
                  m >= 0, m < 1440 else { error = Strings.t("timeline.errTime", default: "Enter a valid HH:MM"); return }
            applyTime(fmtHM(m))
        } else {
            guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else {
                error = Strings.t("timeline.errMinutes", default: "Enter a positive number of minutes"); return
            }
            applyEvery(n)
        }
        // setTrigger already refreshes; the option path (setOptionValue) does
        // not, and the Timeline reads f.schedule from a refresh()-time snapshot
        // -- so re-read the catalog here or the edited marker keeps its old
        // value until some unrelated refresh.
        store.refresh()
        dismiss()
    }

    // Two write paths: a real action trigger (setTrigger) vs a descriptor entry
    // bound to a feature option (setOptionValue) -- the same paths the Shortcut
    // Map and the Settings form use, so no new persistence logic here.
    private func applyTime(_ hhmm: String) {
        if let actionId = item.actionId {
            _ = store.setTrigger(item.featureId, actionId,
                                 TriggerSpec(type: "schedule", at: hhmm))
        } else if let key = item.optionKey,
                  let opt = optionInfo(key) {
            store.setOptionValue(item.featureId, opt, hhmm)
        }
    }

    private func applyEvery(_ minutes: Int) {
        if let actionId = item.actionId {
            _ = store.setTrigger(item.featureId, actionId,
                                 TriggerSpec(type: "schedule", everyMin: minutes))
        } else if let key = item.optionKey, let opt = optionInfo(key) {
            store.setOptionValue(item.featureId, opt, minutes)
        }
    }

    private func optionInfo(_ key: String) -> OptionInfo? {
        store.features.first { $0.id == item.featureId }?.options.first { $0.key == key }
    }
}
