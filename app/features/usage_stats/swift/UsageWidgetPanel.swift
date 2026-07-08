// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Usage widget (desktop-pinned daily stats card)

/// Typed payload for the usage widget -- the Lua side computes, Swift renders.
/// Parsed from the table usage_stats passes across the bridge.
struct UsageWidgetData {
    struct ContextRow { let name: String; let secs: Double }
    struct AppRow { let name: String; let secs: Double; let contexts: [ContextRow] }
    struct Day { let label: String; let secs: Double; let isToday: Bool }
    let total: Double
    let updated: String
    let avg: Double?         // average of past days that have data
    let weekTotal: Double
    let apps: [AppRow]       // already sorted + truncated by the feature
    let week: [Day]          // oldest first, last entry is today

    init?(_ dict: [String: Any]) {
        guard let total = dict["total"] as? Double else { return nil }
        self.total = total
        self.updated = dict["updated"] as? String ?? ""
        self.avg = dict["avg"] as? Double
        self.weekTotal = dict["weekTotal"] as? Double ?? 0
        self.apps = ((dict["apps"] as? [Any]) ?? []).compactMap {
            guard let d = $0 as? [String: Any],
                  let n = d["app"] as? String, let s = d["secs"] as? Double else { return nil }
            let contexts = ((d["contexts"] as? [Any]) ?? []).compactMap { c -> ContextRow? in
                guard let cd = c as? [String: Any],
                      let cn = cd["name"] as? String, let cs = cd["secs"] as? Double
                else { return nil }
                return ContextRow(name: cn, secs: cs)
            }
            return AppRow(name: n, secs: s, contexts: contexts)
        }
        self.week = ((dict["week"] as? [Any]) ?? []).compactMap {
            guard let d = $0 as? [String: Any],
                  let l = d["label"] as? String, let s = d["secs"] as? Double else { return nil }
            return Day(label: l, secs: s, isToday: (d["today"] as? Bool) ?? false)
        }
    }
}

/// NSView with a top-down coordinate system (widget layout reads like a list).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The donor usageWidget rebuilt natively: a dark card pinned to the
/// bottom-left of the screen at DESKTOP level (above the wallpaper, below all
/// windows -- the Hammerspoon hs.drawing.windowLevels.desktop trick), showing
/// today's total, the top apps with bars, and a 7-day chart. Click-through.
@MainActor
final class UsageWidgetPanel {
    private let panel: NSPanel
    private let card = FlippedView()
    static let width: CGFloat = 300
    static let height: CGFloat = 430
    private static let pad: CGFloat = 14
    private static let margin: CGFloat = 10

    /// screenIndex: 1 = primary; 2 = the second display when present (falls
    /// back to primary on single-display setups).
    init(screenIndex: Int = 1) {
        let screens = NSScreen.screens
        let target = (screenIndex >= 2 && screens.count >= 2) ? screens[1] : screens.first
        let screen = target?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.minX + Self.margin, y: screen.minY + Self.margin,
                          width: Self.width, height: Self.height)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card is ALWAYS a dark card, but the labels use adaptive semantic
        // colors (.labelColor / .secondaryLabelColor / ...). Pin the widget
        // subtree to dark appearance so those colors resolve light-on-dark in
        // BOTH light and system dark mode -- otherwise light mode paints near-
        // black text on the dark card and it's unreadable.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true

        card.frame = NSRect(origin: .zero, size: rect.size)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.88).cgColor
        card.layer?.cornerRadius = 12
        panel.contentView = card
        panel.orderFrontRegardless()
    }

    func setData(_ d: UsageWidgetData) {
        card.subviews.forEach { $0.removeFromSuperview() }
        let w = Self.width - 2 * Self.pad
        var y = Self.pad

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor, x: CGFloat, y: CGFloat,
                   width: CGFloat, align: NSTextAlignment = .left) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.alignment = align
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: x, y: y, width: width, height: size + 6)
            card.addSubview(l)
            return l
        }
        func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                 color: NSColor, radius: CGFloat) {
            let v = NSView(frame: NSRect(x: x, y: y, width: max(width, 2), height: height))
            v.wantsLayer = true
            v.layer?.backgroundColor = color.cgColor
            v.layer?.cornerRadius = radius
            card.addSubview(v)
        }

        let accent = NSColor(calibratedRed: 0.31, green: 0.765, blue: 0.969, alpha: 1)
        let trackColor = NSColor(calibratedWhite: 1, alpha: 0.08)

        // Header: "Today" + total (+ avg of past days).
        _ = label("Today", size: 13, weight: .semibold, color: .secondaryLabelColor,
                  x: Self.pad, y: y + 4, width: 80)
        var totalText = Self.formatTime(d.total)
        if let avg = d.avg { totalText += "   avg " + Self.formatTime(avg) }
        _ = label(totalText, size: 18, weight: .bold, color: .white,
                  x: Self.pad + 60, y: y, width: w - 60, align: .right)
        y += 26
        _ = label("Updated " + d.updated, size: 10, weight: .regular,
                  color: .tertiaryLabelColor, x: Self.pad, y: y, width: w)
        y += 24

        // App rows: name + time, then a proportional bar.
        if d.apps.isEmpty {
            _ = label("No data yet", size: 12, weight: .regular,
                      color: .tertiaryLabelColor, x: Self.pad, y: y + 40, width: w,
                      align: .center)
            y += 70
        } else {
            let maxSecs = max(d.apps.first?.secs ?? 1, 1)
            let chartReserve: CGFloat = 110   // divider + week section must fit
            for row in d.apps {
                if y > Self.height - chartReserve - 34 { break }   // clip, don't overflow
                _ = label(row.name, size: 12, weight: .medium, color: .labelColor,
                          x: Self.pad, y: y, width: w - 70)
                _ = label(Self.formatTime(row.secs), size: 12, weight: .semibold,
                          color: .secondaryLabelColor,
                          x: Self.pad + w - 70, y: y, width: 70, align: .right)
                y += 20
                bar(x: Self.pad, y: y, width: w, height: 4, color: trackColor, radius: 2)
                bar(x: Self.pad, y: y, width: w * row.secs / maxSecs, height: 4,
                    color: accent, radius: 2)
                y += 8
                // Context sub-rows: domain / project breakdown (donor parity), then an
                // "Other" remainder so the sub-rows account for the app's whole time
                // (absorbs incognito, untrackable pages, the tail beyond the top few,
                // and pre-consent time -- never labeled as private). Shown only when
                // there ARE real sites, so it reads as a remainder, not a 100% bucket.
                for c in row.contexts {
                    if y > Self.height - chartReserve - 14 { break }
                    _ = label(c.name, size: 10, weight: .regular,
                              color: .tertiaryLabelColor,
                              x: Self.pad + 10, y: y, width: w - 70)
                    _ = label(Self.formatTime(c.secs), size: 10, weight: .regular,
                              color: .tertiaryLabelColor,
                              x: Self.pad + w - 60, y: y, width: 60, align: .right)
                    y += 13
                }
                let shown = row.contexts.reduce(0.0) { $0 + $1.secs }
                let other = row.secs - shown
                if !row.contexts.isEmpty && other >= 30 && y <= Self.height - chartReserve - 14 {
                    _ = label("Other", size: 10, weight: .regular,
                              color: .quaternaryLabelColor,
                              x: Self.pad + 10, y: y, width: w - 70)
                    _ = label(Self.formatTime(other), size: 10, weight: .regular,
                              color: .quaternaryLabelColor,
                              x: Self.pad + w - 60, y: y, width: 60, align: .right)
                    y += 13
                }
                y += 6
            }
        }

        // Divider + week header.
        y += 6
        bar(x: Self.pad, y: y, width: w, height: 1,
            color: NSColor(calibratedWhite: 1, alpha: 0.06), radius: 0)
        y += 10
        _ = label("This Week", size: 10, weight: .semibold, color: .secondaryLabelColor,
                  x: Self.pad, y: y, width: 120)
        _ = label(Self.formatTime(d.weekTotal), size: 10, weight: .regular,
                  color: .secondaryLabelColor, x: Self.pad + w - 120, y: y, width: 120,
                  align: .right)
        y += 20

        // 7-day chart: bars bottom-aligned, time label only on the tallest day.
        let maxDay = max(d.week.map(\.secs).max() ?? 1, 1)
        let colW = (w - CGFloat(max(d.week.count - 1, 1)) * 4) / CGFloat(max(d.week.count, 1))
        let chartH: CGFloat = 40
        for (i, day) in d.week.enumerated() {
            let x = Self.pad + CGFloat(i) * (colW + 4)
            if day.secs == maxDay && day.secs >= 60 {
                _ = label(Self.formatTime(day.secs), size: 8, weight: .regular,
                          color: .secondaryLabelColor, x: x - 10, y: y, width: colW + 20,
                          align: .center)
            }
            let h = max(chartH * day.secs / maxDay, 2)
            bar(x: x, y: y + 12 + (chartH - h), width: colW, height: h,
                color: day.isToday ? accent.withAlphaComponent(0.7) : accent, radius: 2)
            _ = label(day.label, size: 9, weight: .regular,
                      color: day.isToday ? .secondaryLabelColor : .tertiaryLabelColor,
                      x: x, y: y + 14 + chartH, width: colW, align: .center)
        }
    }

    // Delegates to the shared usageTimeString so the widget and the Usage report
    // format time identically (see FeatureChrome.swift).
    static func formatTime(_ secs: Double) -> String { usageTimeString(secs) }

    func close() { panel.orderOut(nil) }
}
