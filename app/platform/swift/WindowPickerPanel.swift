// Panels.swift split: one self-owned native UI surface (see Panels.swift for the
// shared FloatingPanel base and the rationale for our own panels).
//
// A one-shot MULTI-SELECT picker: a titled, checkboxed list where every row is
// pre-checked and the user unchecks the ones to leave out, then confirms. Window
// Deck opens it on every enter ("Deck which windows?"). It deliberately does NOT
// reuse ChooserPanel: that one is single-select + searchable and backs the
// command palette / window switcher / askChoice, so bolting checkbox + confirm
// state onto it would risk regressions there. This panel shares only the visual
// language (menu material, rounded card, accent selection pill via ChooserRowView,
// the app-icon token helper ChooserPanel.icon(for:)).
//
// Keys (a local monitor, like ChooserPanel's quick-keys -- the panel is a
// non-activating key panel, so we drive selection ourselves rather than lean on
// the responder chain): up/down move the focus pill, space toggles the focused
// row's checkbox, return confirms (refused with a beep below `minPick`), escape
// cancels. Click toggles a row too. onDone gets the 1-based CHECKED indices, or
// nil on cancel / click-away.

import AppKit

struct WindowPickerEntry {
    let text: String
    let subText: String?
    let iconToken: String?   // "appicon:<bundleID>" / "file:..." / "symbol:..."
    let color: String        // "#RRGGBB" border-color preview ("" = none shown)
}

@MainActor
final class WindowPickerPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let panel: FloatingPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleIcon = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgePill = NSView()
    private let headerBackground = NSView()
    private let headerDivider = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerDivider = NSView()
    private let hintLabel = NSTextField(labelWithString: "")   // teaches the space=toggle gesture
    private let cancelButton = NSButton()
    private let submitButton = NSButton()                      // the primary "Deck N windows" action
    private var footerRegionY: CGFloat = 0

    private let titleText: String
    private let entries: [WindowPickerEntry]
    private var checked: [Bool]
    private var colors: [String]      // live per-row color (click the dot to cycle)
    private let palette: [String]     // cycle order for recoloring; empty = no swatches
    private let minPick: Int
    private let onDone: ([Int]?, [String], Bool) -> Void
    private let heroLabel = NSTextField(labelWithString: "")   // caller-supplied text
    private let heroSwitch = NSSwitch()
    private var heroOn: Bool
    private let hasHeroRow: Bool   // opt-in: only shown when the caller passes a label

    private var keyMonitor: Any?
    private var isClosing = false

    /// HUDScale factor of the screen the picker is shown on -- resolved in
    /// `show(on:)`, before `applyScale()` + `layout()` size anything from it.
    /// The statics below are the unscaled design sizes; every use multiplies by it.
    private var s: CGFloat = 1
    private let content = NSVisualEffectView()

    private static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 50
    private static let maxListHeight: CGFloat = 460
    /// Kept clear of the screen's edges when the list is capped to fit it.
    private static let screenMargin: CGFloat = 40
    private static let titleHeight: CGFloat = 46
    private static let footerHeight: CGFloat = 48
    private static let edgeInset: CGFloat = 18
    private static let checkboxSlot: CGFloat = 22   // leading checkbox column width
    private static let swatchSize: CGFloat = 16     // trailing color-dot diameter

    init(title: String, entries: [WindowPickerEntry], minPick: Int, palette: [String],
         heroLabel: String, heroOn: Bool, onDone: @escaping ([Int]?, [String], Bool) -> Void) {
        self.titleText = title
        self.entries = entries
        self.checked = Array(repeating: true, count: entries.count)   // all pre-checked
        self.colors = entries.map { $0.color }
        self.palette = palette
        self.minPick = max(0, minPick)
        self.heroOn = heroOn
        self.hasHeroRow = !heroLabel.isEmpty
        self.onDone = onDone

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: WindowPickerPanel.width, height: 300),
                              level: .floating,
                              collectionBehavior: [.canJoinAllSpaces, .transient],
                              keyable: true, mouseTransparent: false)
        super.init()
        panel.hidesOnDeactivate = false

        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.masksToBounds = true

        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        content.addSubview(headerBackground)

        titleIcon.contentTintColor = .controlAccentColor
        titleIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(titleIcon)

        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.stringValue = title
        content.addSubview(titleLabel)

        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgePill.wantsLayer = true
        badgePill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        badgePill.layer?.borderWidth = 1
        badgePill.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        badgePill.addSubview(badgeLabel)
        content.addSubview(badgePill)

        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(headerDivider)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none   // it's first responder for key delivery, no ring
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.drawsBackground = false
        content.addSubview(scrollView)

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(footerDivider)

        // Left: a hint teaching the non-obvious gestures -- space toggles the
        // focused row; clicking a row's color dot recolors its border.
        // (Enter's job is unambiguous: it presses Deck.)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = palette.isEmpty ? "space  toggle" : "space  toggle    ·    click dot  recolor"
        content.addSubview(hintLabel)

        // Right: Cancel + the primary accent "Deck N windows" button, so it is
        // never in doubt that committing the DECK (not selecting a row) is what
        // confirm does. Enter/click both fire it; it disables below the minimum.
        cancelButton.bezelStyle = .rounded
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        content.addSubview(cancelButton)

        submitButton.bezelStyle = .rounded
        submitButton.bezelColor = .controlAccentColor
        submitButton.target = self
        submitButton.action = #selector(submitClicked)
        content.addSubview(submitButton)

        // Opt-in row above the footer: the caller's label + a switch (Window
        // Deck uses it for its Hero mode). Omitted entirely when no label is
        // passed, so askWindows stays a feature-agnostic picker.
        if hasHeroRow {
            self.heroLabel.textColor = .labelColor
            self.heroLabel.stringValue = heroLabel
            content.addSubview(self.heroLabel)
            heroSwitch.state = heroOn ? .on : .off
            heroSwitch.target = self
            heroSwitch.action = #selector(heroChanged)
            content.addSubview(heroSwitch)
        }

        panel.contentView = content
        panel.delegate = self
        applyScale()
    }

    /// Every font / radius / row height / control size that depends on `s`.
    /// Re-run by `show` once the target screen (and so the factor) is known.
    private func applyScale() {
        content.layer?.cornerRadius = 12 * s
        titleIcon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18 * s, weight: .medium))
        titleLabel.font = .systemFont(ofSize: 18 * s, weight: .bold)
        badgeLabel.font = .systemFont(ofSize: 12 * s, weight: .medium)
        badgePill.layer?.cornerRadius = 11 * s
        tableView.rowHeight = Self.rowHeight * s
        hintLabel.font = .systemFont(ofSize: 11.5 * s)
        heroLabel.font = .systemFont(ofSize: 13 * s)
        // A `.rounded` push button draws its bezel at its control size's FIXED
        // height (28pt at `.large`), whatever its frame, so past ~1.8x the label
        // outgrows it. A scaled panel uses `.flexiblePush`, whose bezel fills the
        // frame the layout sizes by the factor; the base size keeps `.rounded`.
        // NSSwitch has no flexible form, so it steps up a control size instead.
        let size: NSControl.ControlSize = s >= 1.3 ? .large : .regular
        for b in [cancelButton, submitButton] {
            b.bezelStyle = size == .large ? .flexiblePush : .rounded
            b.controlSize = size
            b.font = .systemFont(ofSize: 13 * s)
        }
        heroSwitch.controlSize = size
    }

    @objc private func heroChanged() { heroOn = (heroSwitch.state == .on) }

    // MARK: public API

    var isVisible: Bool { panel.isVisible }

    /// `screen` (AppKit coords) centers the picker on THAT screen -- the deck
    /// passes the display the user just picked, which need not be the one
    /// holding key focus (NSScreen.main). Without it: the main screen.
    func show(on screen: NSRect? = nil) {
        isClosing = false
        let target = screen ?? NSScreen.main?.visibleFrame
        s = HUDScale.factor(forRect: target)
        applyScale()
        tableView.reloadData()   // row views are built with the factor current at load
        refreshHeaderAndFooter()
        layout(fitting: target?.height)
        panel.center()
        if let target {
            var f = panel.frame
            f.origin.x = target.midX - f.width / 2
            f.origin.y = target.midY + 60
            panel.setFrame(f, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)   // a key responder so keyDown flows (no search field here)
        if !entries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        installKeys()
    }

    func close() {
        isClosing = true
        removeKeys()
        panel.orderOut(nil)
    }

    // Test drivers (used by @testable swift integration tests; the headless Lua
    // suite drives the fake adapter's own picker instead). Not part of the
    // Lua/feature contract.
    var checkedIndices: [Int] { (0..<entries.count).filter { checked[$0] }.map { $0 + 1 } }
    var rowColors: [String] { colors }
    func debugToggle(_ row: Int) { guard row >= 1, row <= entries.count else { return }; toggle(row - 1) }
    func debugCycleColor(_ row: Int) { guard row >= 1, row <= entries.count else { return }; cycleColor(row - 1) }
    func debugConfirm() { confirm() }
    func debugCancel() { cancel() }

    // MARK: keyboard (local monitor)

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 126: self.moveSelection(-1); return nil   // up
            case 125: self.moveSelection(1);  return nil   // down
            case 49:  self.toggle(self.selectedRow()); return nil   // space
            case 36, 76: self.confirm(); return nil        // return / enter
            case 53:  self.cancel(); return nil            // escape
            default:  return event
            }
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func selectedRow() -> Int { tableView.selectedRow }

    private func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        var row = tableView.selectedRow
        if row < 0 { row = delta > 0 ? -1 : 0 }
        row += delta
        if row < 0 { row = entries.count - 1 }
        if row >= entries.count { row = 0 }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func toggle(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        checked[row].toggle()
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshHeaderAndFooter()
    }

    private var checkedCount: Int { checked.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Cycle a row's border color to the next palette entry (click its dot).
    private func cycleColor(_ row: Int) {
        guard row >= 0, row < entries.count, !palette.isEmpty else { return }
        let idx = palette.firstIndex(of: colors[row]) ?? -1
        colors[row] = palette[(idx + 1) % palette.count]
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integer: 0))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func confirm() {
        guard checkedCount >= minPick else { NSSound.beep(); return }
        finish((0..<entries.count).filter { checked[$0] }.map { $0 + 1 })
    }

    private func cancel() { finish(nil) }

    private func finish(_ result: [Int]?) {
        guard !isClosing else { return }
        isClosing = true
        removeKeys()
        if panel.isVisible { panel.orderOut(nil) }
        onDone(result, colors, heroOn)
    }

    // MARK: NSWindowDelegate -- click-away dismiss (Spotlight convention)

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, panel.isVisible else { return }
        finish(nil)
    }

    // MARK: header / footer text

    private func refreshHeaderAndFooter() {
        badgeLabel.stringValue = "\(checkedCount) of \(entries.count)"
        let n = checkedCount
        let deck = n == 1 ? "Deck 1 window" : "Deck \(n) windows"
        // The ⏎ glyph on the button makes Enter's target explicit.
        submitButton.attributedTitle = WindowPickerPanel.buttonTitle("\u{23CE}  \(deck)", color: .white,
                                                                     size: 13 * s)
        submitButton.isEnabled = checkedCount >= minPick
        layoutHeader()
        layoutFooter()
    }

    private static func buttonTitle(_ s: String, color: NSColor, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        ])
    }

    @objc private func submitClicked() { confirm() }
    @objc private func cancelClicked() { cancel() }

    // MARK: layout

    /// `available`: the height of the screen the picker goes on. The list takes
    /// only what the rest of the panel leaves of it and scrolls past that --
    /// its scaled cap alone is taller than any screen it scales on, so without
    /// this a long list pushes the footer buttons off the bottom.
    private func layout(fitting available: CGFloat?) {
        let W = Self.width * s
        let topPad: CGFloat = 14 * s, bottomPad: CGFloat = 8 * s
        let titleGap: CGFloat = 10 * s
        let footerPad: CGFloat = 8 * s
        let rowH = Self.rowHeight * s
        let heroBand: CGFloat = hasHeroRow ? 38 * s : 0   // opt-in hero row
        let listPad: CGFloat = 8 * s
        let chrome = topPad + Self.titleHeight * s + titleGap + listPad + heroBand
            + Self.footerHeight * s + footerPad + bottomPad

        var listCap = Self.maxListHeight * s
        if let available {
            listCap = min(listCap, max(rowH, available - chrome - Self.screenMargin))
        }
        var listContent: CGFloat = 0
        if entries.isEmpty {
            listContent = rowH
        } else {
            listContent = min(CGFloat(entries.count) * rowH, listCap)
        }
        let listHeight = listContent + listPad

        let total = chrome + listContent

        var f = panel.frame
        let topEdge = f.maxY
        f.size = NSSize(width: W, height: total)
        f.origin.y = topEdge - total
        panel.setFrame(f, display: true)
        panel.contentView!.frame = NSRect(origin: .zero, size: f.size)

        let E = Self.edgeInset * s
        var y = total - topPad

        let th = Self.titleHeight * s
        let titleY = y - th
        headerBackground.frame = NSRect(x: 0, y: titleY, width: W, height: topPad + th)
        layoutHeader()
        y -= th + titleGap
        headerDivider.frame = NSRect(x: E, y: y + titleGap / 2 - 0.5, width: W - 2 * E, height: 1)

        scrollView.frame = NSRect(x: 0, y: y - listHeight, width: W, height: listHeight)
        tableView.sizeLastColumnToFit()
        y -= listHeight

        // Hero row (opt-in): label on the left, switch flush right.
        if hasHeroRow {
            heroLabel.sizeToFit()
            let lh: CGFloat = 17 * s
            heroLabel.frame = NSRect(x: E, y: y - heroBand + (heroBand - lh) / 2,
                                     width: 300 * s, height: lh)
            let swSize = heroSwitch.intrinsicContentSize
            heroSwitch.frame = NSRect(x: W - E - swSize.width,
                                      y: y - heroBand + (heroBand - swSize.height) / 2,
                                      width: swSize.width, height: swSize.height)
        }
        y -= heroBand

        footerDivider.frame = NSRect(x: E, y: y, width: W - 2 * E, height: 1)
        footerRegionY = y
        layoutFooter()
    }

    /// Footer buttons -- right-flush accent Submit + Cancel, the space-toggle hint
    /// on the left. Re-run on toggle so the accent button's width tracks the
    /// changing "Deck N windows" title.
    private func layoutFooter() {
        let W = Self.width * s
        let E = Self.edgeInset * s
        let bh: CGFloat = 30 * s
        let by = max(0, (footerRegionY - bh) / 2)

        submitButton.sizeToFit()
        let sw = max(150 * s, submitButton.frame.width + 22 * s)
        submitButton.frame = NSRect(x: W - E - sw, y: by, width: sw, height: bh)

        cancelButton.sizeToFit()
        let cw = max(78 * s, cancelButton.frame.width + 16 * s)
        cancelButton.frame = NSRect(x: W - E - sw - 10 * s - cw, y: by, width: cw, height: bh)

        hintLabel.sizeToFit()
        let hh: CGFloat = 15 * s
        hintLabel.frame = NSRect(x: E, y: by + (bh - hh) / 2, width: 200 * s, height: hh)
    }

    /// Header row (icon + title + right-flush count pill) -- re-run on toggle so
    /// the badge width tracks the changing count.
    private func layoutHeader() {
        let W = Self.width * s
        let E = Self.edgeInset * s
        let th = Self.titleHeight * s
        let titleY = headerBackground.frame.minY
        let icon: CGFloat = 22 * s

        titleIcon.frame = NSRect(x: E, y: titleY + (th - icon) / 2, width: icon, height: icon)

        badgeLabel.sizeToFit()
        let pillTextW = badgeLabel.frame.width
        let pillOuterW = pillTextW + 20 * s
        let pH: CGFloat = 22 * s
        let bH: CGFloat = 15 * s
        badgePill.frame = NSRect(x: W - E - pillOuterW, y: titleY + (th - pH) / 2, width: pillOuterW, height: pH)
        badgeLabel.frame = NSRect(x: 10 * s, y: (pH - bH) / 2, width: pillTextW, height: bH)

        let titleX = E + icon + 10 * s
        let titleAvail = (W - E - pillOuterW - 12 * s) - titleX
        let tH: CGFloat = 22 * s
        titleLabel.frame = NSRect(x: titleX, y: titleY + (th - tH) / 2, width: max(40 * s, titleAvail), height: tH)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ChooserRowView()   // shared accent selection pill
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = NSView()
        let rowH = Self.rowHeight * s
        let E = Self.edgeInset * s
        let W = Self.width * s

        // Leading checkbox (checked = accent-filled, unchecked = hollow square).
        let box = NSImageView()
        let symbol = checked[row] ? "checkmark.square.fill" : "square"
        box.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18 * s, weight: .regular))
        // Unchecked = a clearly-visible hollow box (secondary, not tertiary): the
        // "this window is excluded" affordance is the whole point of the picker.
        box.contentTintColor = checked[row] ? .controlAccentColor : .secondaryLabelColor
        box.imageScaling = .scaleProportionallyDown
        let boxD: CGFloat = 20 * s
        box.frame = NSRect(x: E, y: (rowH - boxD) / 2, width: boxD, height: boxD)
        cell.addSubview(box)

        var x = E + (Self.checkboxSlot + 8) * s

        if let token = e.iconToken, let icon = ChooserPanel.icon(for: token) {
            let iconD: CGFloat = 30 * s
            let iv = NSImageView(frame: NSRect(x: x, y: (rowH - iconD) / 2, width: iconD, height: iconD))
            iv.image = icon
            if token.hasPrefix("symbol:") {
                iv.imageScaling = .scaleProportionallyDown
                iv.contentTintColor = .secondaryLabelColor
            } else {
                iv.imageScaling = .scaleProportionallyUpOrDown
            }
            cell.addSubview(iv)
            x += 38 * s
        }

        // Trailing color dot: previews the border color this window's deck ring
        // will use; clicking it cycles the palette (see rowClicked's hit test).
        var rightPad: CGFloat = 10 * s
        if !colors[row].isEmpty, let c = NSColor(hexRGB: colors[row]) {
            let d = Self.swatchSize * s
            let swatch = NSView(frame: NSRect(x: W - E - d,
                                              y: (rowH - d) / 2, width: d, height: d))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = d / 2
            swatch.layer?.backgroundColor = c.cgColor
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
            cell.addSubview(swatch)
            rightPad = d + 18 * s
        }

        let textW = max(40 * s, W - E - rightPad - x)
        let title = NSTextField(labelWithString: e.text)
        title.font = .systemFont(ofSize: 14 * s)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        if let sub = e.subText, !sub.isEmpty {
            let titleH: CGFloat = 18 * s, subH: CGFloat = 15 * s, gap: CGFloat = 1 * s
            let block = titleH + gap + subH
            let topPad = (rowH - block) / 2
            title.frame = NSRect(x: x, y: rowH - topPad - titleH, width: textW, height: titleH)
            cell.addSubview(title)

            let subLabel = NSTextField(labelWithString: sub)
            subLabel.font = .systemFont(ofSize: 12 * s)
            subLabel.textColor = .tertiaryLabelColor
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: x, y: rowH - topPad - titleH - gap - subH, width: textW, height: subH)
            cell.addSubview(subLabel)
        } else {
            let titleH: CGFloat = 18 * s
            title.frame = NSRect(x: x, y: (rowH - titleH) / 2, width: textW, height: titleH)
            cell.addSubview(title)
        }
        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        // A click on the trailing color dot recolors; anywhere else toggles.
        if !palette.isEmpty, !colors[row].isEmpty, let ev = NSApp.currentEvent {
            let p = tableView.convert(ev.locationInWindow, from: nil)
            let dotMinX = tableView.bounds.width - (Self.edgeInset + Self.swatchSize + 8) * s
            if p.x >= dotMinX { cycleColor(row); return }
        }
        toggle(row)
    }
}
