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

/// NSView with a top-down coordinate system (widget layout reads like a list),
/// drawing the card's own fill + edge.
///
/// Layer colors are the one place a theme flip needs care: a CGColor is a
/// resolved value, not a promise, so it cannot re-resolve itself. `updateLayer`
/// is AppKit's answer -- the default `viewDidChangeEffectiveAppearance` already
/// invalidates the view, so this re-runs on every flip, and inside it a plain
/// `.cgColor` resolves against the view's NEW appearance. Doing the same work
/// from `viewDidChangeEffectiveAppearance` instead is the trap: there the
/// current drawing appearance is still the OLD one.
private final class CardView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.backgroundColor = UsageWidgetPanel.cardFill.cgColor
        layer?.borderColor = UsageWidgetPanel.cardBorder.cgColor
    }
}

// The bars, tracks and dividers use the shared `TintedView` from Panels.swift --
// same updateLayer contract as CardView above.

/// The donor usageWidget rebuilt natively: a card pinned to the bottom-left of
/// the screen at DESKTOP level (above the wallpaper, below all windows -- the
/// Hammerspoon hs.drawing.windowLevels.desktop trick), showing today's total,
/// the top apps with bars, and a 7-day chart. Click-through.
///
/// Unlike the `.hudWindow` key legends, this one FOLLOWS the app theme
/// (AppearancePreference): it is persistent desktop furniture the user looks at
/// all day, not a two-second overlay flashed over another app's window, so a
/// permanently dark card is the thing that would look foreign on a light
/// desktop. That means the panel pins no appearance of its own -- it inherits
/// NSApp's -- and every non-semantic color below has a light and a dark form.
@MainActor
final class UsageWidgetPanel {
    private let panel: NSPanel
    private let card = CardView()
    static let width: CGFloat = 300
    static let height: CGFloat = 430
    private static let pad: CGFloat = 14
    private static let margin: CGFloat = 10

    // The DESIGN colors below (no semantic equivalent) are two-form via
    // `NSColor.dynamic`. Anything that is really just ink over the card uses the
    // semantic color with its alpha applied late by TintedView instead -- see
    // trackAlpha/dividerAlpha and that class's note.

    /// The card itself. Translucent either way so the wallpaper shows through,
    /// like the donor did.
    static let cardFill = NSColor.dynamic("usageWidgetCard",
        light: NSColor(calibratedWhite: 0.99, alpha: 0.90),
        dark:  NSColor(calibratedWhite: 0.12, alpha: 0.88))

    /// A near-white card on a pale wallpaper needs an edge to read as a card;
    /// the dark one never did, so it keeps none.
    static let cardBorder = NSColor.dynamic("usageWidgetBorder",
        light: NSColor(calibratedWhite: 0, alpha: 0.12),
        dark:  .clear)

    /// Bars + the today column. The donor's sky blue stays for dark; on a light
    /// card it is too pale against white, so light gets a deeper blue.
    private static let accent = NSColor.dynamic("usageWidgetAccent",
        light: NSColor(calibratedRed: 0.086, green: 0.463, blue: 0.780, alpha: 1),
        dark:  NSColor(calibratedRed: 0.310, green: 0.765, blue: 0.969, alpha: 1))

    // The bar track and the section divider are ink over the card, so they are
    // `.labelColor` with the alpha applied LATE by TintedView -- these alphas are
    // the donor's original dark values (0.08 / 0.06), which hand-written two-form
    // colors had quietly drifted to 0.10 / 0.08.
    private static let trackAlpha: CGFloat = 0.08
    private static let dividerAlpha: CGFloat = 0.06

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
        // No `panel.appearance` pin: the widget inherits NSApp's, so the theme
        // preference reaches it. The text already uses adaptive semantic colors
        // (.labelColor / .secondaryLabelColor / ...), which is what makes that
        // safe -- they flip with the card instead of staying light-on-light.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true

        card.frame = NSRect(origin: .zero, size: rect.size)
        card.wantsLayer = true
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
                 color: NSColor, alpha: CGFloat? = nil, radius: CGFloat) {
            let v = TintedView(frame: NSRect(x: x, y: y, width: max(width, 2), height: height))
            v.fill = color
            v.fillAlpha = alpha
            v.layer?.cornerRadius = radius
            card.addSubview(v)
        }

        let accent = Self.accent

        // Header: "Today" + total (+ avg of past days).
        _ = label("Today", size: 13, weight: .semibold, color: .secondaryLabelColor,
                  x: Self.pad, y: y + 4, width: 80)
        var totalText = Self.formatTime(d.total)
        if let avg = d.avg { totalText += "   avg " + Self.formatTime(avg) }
        _ = label(totalText, size: 18, weight: .bold, color: .labelColor,
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
                bar(x: Self.pad, y: y, width: w, height: 4,
                    color: .labelColor, alpha: Self.trackAlpha, radius: 2)
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
            color: .labelColor, alpha: Self.dividerAlpha, radius: 0)
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
                color: accent, alpha: day.isToday ? 0.7 : nil, radius: 2)
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
