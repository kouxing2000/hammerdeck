// Panels.swift split: one self-owned native UI surface (see Panels.swift
// for the shared KeyablePanel base and the rationale for our own panels).

import AppKit

// MARK: - Chooser (searchable picker; also backs askChoice dialogs)

struct ChooserEntry {
    let text: String
    let subText: String?
    let iconToken: String?   // "appicon:<bundleID>"
    let valid: Bool          // false = info row, not selectable
    var shortcut: String? = nil  // trigger/shortcut preview, rendered flush-right
}

/// hs.chooser-equivalent: a floating search field + list. onSelect receives the
/// 1-based index into the ORIGINAL entries array (nil = dismissed/escape).
@MainActor
final class ChooserPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let panel: KeyablePanel
    private let titleLabel = NSTextField(labelWithString: "")  // real header title (not the search placeholder)
    private let titleIcon = NSImageView()   // optional leading glyph in the header
    private let badgeLabel = NSTextField(labelWithString: "")  // optional right-flush count badge
    private let searchField = NSTextField()
    private let searchDivider = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerDivider = NSView()
    private let footerView = NSView()     // pinned, non-scrolling strip for info/stat lines

    private var entries: [ChooserEntry] = []
    private var filtered: [Int] = []     // indices into entries
    private var titleText = ""           // empty = no header band (e.g. the command palette)
    private var titleSymbol: String?     // optional SF Symbol shown before the title
    private var titleBadge: String?      // optional count/status badge, right-flush on the title line
    private var footerLines: [String] = []  // empty = no footer strip
    private let searchSubText: Bool
    private let onSelect: (Int?) -> Void
    private let onHide: () -> Void
    private let badgePill = NSView()          // inline pill wrapping the badge text
    private let headerBackground = NSView()   // tinted accent band behind the header
    private var keyMonitor: Any?              // cmd+1..9 quick-pick, live while shown
    // Re-entrancy guard for the close cascade: any deliberate teardown
    // (finish/select/hide/close) sets this before orderOut so the resulting
    // windowDidResignKey doesn't loop back into a second dismiss. Re-armed
    // (cleared) on show() because choosers are REUSED (window_switcher keeps one
    // across invocations), so this can't be a one-shot latch.
    private var isClosing = false

    private static let width: CGFloat = 680
    private static let rowHeight: CGFloat = 38        // single-line row (no source/subtitle)
    private static let rowHeightTwoLine: CGFloat = 52 // stacked: title over a dim source line
    private static let maxListHeight: CGFloat = 460   // cap before the list scrolls
    private static let searchHeight: CGFloat = 34
    private static let titleHeight: CGFloat = 46
    private static let footerLineHeight: CGFloat = 20
    private static let keycapWidth: CGFloat = 32
    private static let keycapHeight: CGFloat = 19
    private static let edgeInset: CGFloat = 18   // one consistent left/right margin for header, rows, chips

    init(searchSubText: Bool, onSelect: @escaping (Int?) -> Void, onHide: @escaping () -> Void) {
        self.searchSubText = searchSubText
        self.onSelect = onSelect
        self.onHide = onHide

        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: ChooserPanel.width, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.hidesOnDeactivate = false

        let content = NSVisualEffectView()
        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true   // so the footer strip's tint honors the rounded corners

        // Tinted accent band: added first so it renders behind all header elements.
        // Fills the full header zone from the top rounded corner down to the divider.
        headerBackground.wantsLayer = true
        headerBackground.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        headerBackground.isHidden = true
        content.addSubview(headerBackground)

        // Real header title -- distinct from the search placeholder. Hidden
        // (zero-height) when no title is set, so the command palette is unchanged.
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        content.addSubview(titleLabel)

        titleIcon.imageScaling = .scaleProportionallyUpOrDown
        titleIcon.contentTintColor = .controlAccentColor
        titleIcon.isHidden = true
        content.addSubview(titleIcon)

        badgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center

        // Pill container: rounded capsule rendered inline with the title group.
        badgePill.wantsLayer = true
        badgePill.layer?.cornerRadius = 10
        badgePill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        badgePill.layer?.borderWidth = 1
        badgePill.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        badgePill.isHidden = true
        badgePill.addSubview(badgeLabel)
        content.addSubview(badgePill)

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 18)
        searchField.delegate = self
        content.addSubview(searchField)

        searchDivider.wantsLayer = true
        searchDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(searchDivider)

        tableView.headerView = nil
        tableView.rowHeight = ChooserPanel.rowHeight
        tableView.backgroundColor = .clear
        // .plain (not .inset): .inset adds its OWN automatic left/right insets on
        // top of our cell margins, so row content drifts right of the header and
        // the edges stop lining up. We draw our own selection pill (ChooserRowView),
        // so we don't need .inset's styling -- .plain lets us own every margin.
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
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

        // Footer strip: a darker, pinned (non-scrolling) band that holds the
        // non-actionable info/stat lines, kept visually distinct from the rows.
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(footerDivider)
        footerView.wantsLayer = true
        footerView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        content.addSubview(footerView)

        panel.contentView = content
        panel.delegate = self
    }

    // MARK: public API (mirrors the adapter chooser handle)

    func setPlaceholder(_ text: String) {
        searchField.placeholderString = text
    }

    /// A prominent header title above the search field (its own bold label, not
    /// the dim search placeholder). Empty hides the header band entirely.
    /// `symbol` is an optional leading SF Symbol; `badge` an optional count/status
    /// pill shown inline after the title (both opt-in, off for plain dialogs).
    func setTitle(_ text: String, symbol: String? = nil, badge: String? = nil) {
        titleText = text
        titleLabel.stringValue = text
        titleSymbol = (symbol?.isEmpty == false) ? symbol : nil
        titleBadge = (badge?.isEmpty == false) ? badge : nil
        if let sym = titleSymbol {
            titleIcon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        } else {
            titleIcon.image = nil
        }
        badgeLabel.stringValue = titleBadge ?? ""
        layout()
    }

    /// Non-actionable context lines pinned in the footer strip below the list
    /// (e.g. "Worked today: 7h 11m"). Empty hides the strip.
    func setFooter(_ lines: [String]) {
        footerLines = lines
        layout()
    }

    func setChoices(_ list: [ChooserEntry]) {
        entries = list
        applyFilter()
    }

    func setQuery(_ q: String?) {
        searchField.stringValue = q ?? ""
        applyFilter()
    }

    func show() {
        isClosing = false   // re-arm: this panel may have been dismissed before
        layout()
        panel.center()
        if let screen = NSScreen.main {
            var f = panel.frame
            f.origin.y = screen.visibleFrame.midY + 60
            panel.setFrame(f, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if selectedRow() == 0 { selectFirstValid() }
        installQuickKeys()
    }

    func hide() {
        guard panel.isVisible else { return }
        isClosing = true
        removeQuickKeys()
        panel.orderOut(nil)
        onHide()
    }

    // MARK: quick-pick (cmd+1..9 fires the Nth visible row)

    /// While the chooser is key, cmd+<digit> selects and triggers that row of
    /// the CURRENT (filtered) list -- the digits shown in the left gutter. A
    /// local monitor (not a keyEquivalent) keeps it from colliding with typing.
    private func installQuickKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow,
                  event.modifierFlags.contains(.command),
                  let ch = event.charactersIgnoringModifiers, let d = Int(ch),
                  d >= 1, d <= 9 else { return event }
            self.quickPick(d)
            return nil   // consume even when no such row, so it never beeps/types
        }
    }

    private func removeQuickKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Fire the n-th visible row (1-based). No-op when there is no such row, or
    /// when that row is an info row (valid=false) -- matching click/keyboard,
    /// which also refuse to select info rows.
    private func quickPick(_ n: Int) {
        guard n >= 1, n <= filtered.count, entries[filtered[n - 1]].valid else { return }
        select(n)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: test introspection (read-only; surfaced via Native.chooserSnapshots)
    // Not part of the Lua/feature contract -- see the note on that method.

    /// Whether this panel currently holds key focus. The signal the
    /// focus-handoff test asserts on when one chooser opens another.
    var isKey: Bool { panel.isKeyWindow }
    /// The search-field placeholder -- lets a test tell choosers apart by purpose
    /// ("Run a command" vs "Search windows") without depending on ids.
    var placeholder: String { searchField.placeholderString ?? "" }
    /// Visible (post-filter) row count.
    var visibleRowCount: Int { filtered.count }
    /// The visible rows' primary text, in display order.
    var visibleEntryTexts: [String] { filtered.map { entries[$0].text } }

    /// 1-based selected row in the current (filtered) list; 0 = none.
    func selectedRow() -> Int {
        return tableView.selectedRow >= 0 ? tableView.selectedRow + 1 : 0
    }

    func setSelectedRow(_ n: Int) {
        guard n >= 1, n <= filtered.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: n - 1), byExtendingSelection: false)
        tableView.scrollRowToVisible(n - 1)
    }

    /// Programmatically pick row n (1-based, filtered list) as the user would.
    func select(_ n: Int) {
        guard n >= 1, n <= filtered.count else { return finish(nil) }
        finish(filtered[n - 1] + 1)
    }

    func close() {
        isClosing = true
        removeQuickKeys()
        panel.orderOut(nil)
    }

    // MARK: internals

    private func finish(_ originalIndex: Int?) {
        guard !isClosing else { return }   // ignore re-entry from the orderOut->resignKey cascade
        isClosing = true
        removeQuickKeys()
        if panel.isVisible { panel.orderOut(nil) }
        onSelect(originalIndex)
        onHide()
    }

    // MARK: NSWindowDelegate

    /// Click-away dismiss: when the panel loses key focus to anything external
    /// (user clicked back into their app / another window), cancel it -- the
    /// Spotlight/Alfred convention. Without this a chooser that has lost focus
    /// floats with no keyboard escape (ESC is routed through the search field,
    /// which only gets it while the panel is key). Guarded by isClosing so the
    /// deliberate teardown paths (finish/hide/close) don't recurse here.
    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, panel.isVisible else { return }
        finish(nil)
    }

    private func selectFirstValid() {
        if let i = filtered.firstIndex(where: { entries[$0].valid }) {
            setSelectedRow(i + 1)
        }
    }

    private func applyFilter() {
        let q = searchField.stringValue.lowercased()
        if q.isEmpty {
            filtered = Array(entries.indices)
        } else {
            filtered = entries.indices.filter { i in
                let e = entries[i]
                if e.text.lowercased().contains(q) { return true }
                if searchSubText, let s = e.subText, s.lowercased().contains(q) { return true }
                return false
            }
        }
        tableView.reloadData()
        layout()
        selectFirstValid()
    }

    private func layout() {
        let W = ChooserPanel.width
        let topPad: CGFloat = 14, bottomPad: CGFloat = 8
        let titleGap: CGFloat = 8        // header title -> search
        let afterSearch: CGFloat = 11    // search -> divider -> list
        let footerPad: CGFloat = 7       // padding inside the footer strip

        let hasTitle = !titleText.isEmpty
        let hasFooter = !footerLines.isEmpty
        // Sum real row heights (rows may be one- or two-line) until the pixel
        // budget fills; beyond that the list scrolls. Empty list keeps one row.
        var listContent: CGFloat = 0
        if filtered.isEmpty {
            listContent = ChooserPanel.rowHeight
        } else {
            for i in filtered.indices {
                let h = rowHeightFor(i)
                if i > 0 && listContent + h > ChooserPanel.maxListHeight { break }
                listContent += h
            }
        }
        let listHeight = listContent + 8
        let footerHeight = hasFooter
            ? CGFloat(footerLines.count) * ChooserPanel.footerLineHeight + 2 * footerPad : 0

        let total = topPad
            + (hasTitle ? ChooserPanel.titleHeight + titleGap : 0)
            + ChooserPanel.searchHeight + afterSearch
            + listHeight
            + footerHeight
            + bottomPad

        var f = panel.frame
        let topEdge = f.maxY
        f.size = NSSize(width: W, height: total)
        f.origin.y = topEdge - total
        panel.setFrame(f, display: true)
        panel.contentView!.frame = NSRect(origin: .zero, size: f.size)

        // Place top-down (AppKit y grows upward, so subtract as we descend).
        let E = ChooserPanel.edgeInset
        var y = total - topPad
        if hasTitle {
            let th = ChooserPanel.titleHeight
            let titleY = y - th
            titleLabel.isHidden = false

            // Tinted accent band fills from the top rounded corner to the bottom
            // of the title zone (topPad + titleHeight), clipped by the corner mask.
            headerBackground.isHidden = false
            headerBackground.frame = NSRect(x: 0, y: titleY, width: W, height: topPad + th)

            // Measure each group element so we can center the whole unit.
            let iconW: CGFloat = titleIcon.image != nil ? 22 + 8 : 0
            titleLabel.sizeToFit()

            var pillTextW: CGFloat = 0
            if titleBadge != nil {
                badgeLabel.sizeToFit()   // text set in setTitle()
                pillTextW = badgeLabel.frame.width
            }
            let pillOuterW = pillTextW > 0 ? pillTextW + 20 : 0   // 10px pad each side
            let pillGap: CGFloat = pillOuterW > 0 ? 10 : 0

            // Clamp the title text to whatever the group leaves inside the margins
            // so a long title truncates (…) within bounds instead of overflowing
            // the right edge and being hard-clipped by the corner mask.
            let titleAvail = (W - 2 * E) - iconW - pillGap - pillOuterW
            let titleTextW = max(40, min(titleLabel.frame.width + 4, titleAvail))

            let groupW = iconW + titleTextW + pillGap + pillOuterW
            var cx = max(E, (W - groupW) / 2)

            // Glyph
            if titleIcon.image != nil {
                titleIcon.isHidden = false
                titleIcon.frame = NSRect(x: cx, y: titleY + (th - 22) / 2, width: 22, height: 22)
                cx += 22 + 8
            } else {
                titleIcon.isHidden = true
            }

            // Title text
            titleLabel.frame = NSRect(x: cx, y: titleY + (th - 22) / 2, width: titleTextW, height: 22)
            cx += titleTextW

            // Inline pill badge (part of the centered group, not right-flush)
            if pillOuterW > 0 {
                badgePill.isHidden = false
                let pH: CGFloat = 20
                cx += pillGap
                badgePill.frame = NSRect(x: cx, y: titleY + (th - pH) / 2, width: pillOuterW, height: pH)
                badgePill.layer?.cornerRadius = pH / 2
                badgeLabel.frame = NSRect(x: 10, y: (pH - 15) / 2, width: pillTextW, height: 15)
            } else {
                badgePill.isHidden = true
            }
            y -= th + titleGap
        } else {
            titleLabel.isHidden = true
            titleIcon.isHidden = true
            badgePill.isHidden = true
            headerBackground.isHidden = true
        }

        searchField.frame = NSRect(x: E, y: y - ChooserPanel.searchHeight + 4,
                                   width: W - 2 * E, height: 26)
        y -= ChooserPanel.searchHeight
        searchDivider.frame = NSRect(x: E, y: y + afterSearch / 2 - 0.5, width: W - 2 * E, height: 1)
        y -= afterSearch

        // Full-width scroll/table; cell margins (edgeInset) live inside the cells,
        // so row content lines up with the header and divider above.
        scrollView.frame = NSRect(x: 0, y: y - listHeight, width: W, height: listHeight)
        tableView.sizeLastColumnToFit()
        y -= listHeight

        if hasFooter {
            footerDivider.isHidden = false
            footerView.isHidden = false
            footerDivider.frame = NSRect(x: E, y: y, width: W - 2 * E, height: 1)
            footerView.frame = NSRect(x: 0, y: bottomPad, width: W, height: footerHeight)
            // Lay the lines top-down inside the strip's own coordinate space.
            footerView.subviews.forEach { $0.removeFromSuperview() }
            for (i, line) in footerLines.enumerated() {
                let label = NSTextField(labelWithString: line)
                label.font = .systemFont(ofSize: 11.5)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                label.frame = NSRect(x: E,
                                     y: footerHeight - footerPad - CGFloat(i + 1) * ChooserPanel.footerLineHeight + 2,
                                     width: W - 2 * E, height: 16)
                footerView.addSubview(label)
            }
        } else {
            footerDivider.isHidden = true
            footerView.isHidden = true
        }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    /// A row with a non-empty source/subtitle renders stacked (two lines) and is
    /// taller; rows without one stay single-line. `filteredRow` indexes `filtered`.
    private func rowHeightFor(_ filteredRow: Int) -> CGFloat {
        let e = entries[filtered[filteredRow]]
        let hasSub = (e.subText?.isEmpty == false)
        return hasSub ? ChooserPanel.rowHeightTwoLine : ChooserPanel.rowHeight
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeightFor(row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entries[filtered[row]].valid
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ChooserRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[filtered[row]]
        let cell = NSView()
        let rowH = rowHeightFor(row)
        let hasSub = (e.subText?.isEmpty == false)
        let E = ChooserPanel.edgeInset
        var rightEdge = ChooserPanel.width - E

        // Quick-pick hint (cmd+1..9), rendered as a key-cap chip flush-right for
        // the first nine SELECTABLE rows -- where the eye expects a shortcut on
        // macOS. Vertically centered so it reads as the row's affordance whether
        // the row is one or two lines. Info rows (valid=false) get none.
        if row < 9 && e.valid {
            let cap = ChooserPanel.keycap("⌘\(row + 1)")
            cap.frame.origin = NSPoint(x: rightEdge - ChooserPanel.keycapWidth,
                                       y: (rowH - ChooserPanel.keycapHeight) / 2)
            cell.addSubview(cap)
            rightEdge -= ChooserPanel.keycapWidth + 10
        }

        // Trigger/shortcut preview (command palette), right-aligned, left of the chip.
        if let sc = e.shortcut, !sc.isEmpty {
            let scW: CGFloat = 96
            let scLabel = NSTextField(labelWithString: sc)
            scLabel.font = .systemFont(ofSize: 11)
            scLabel.textColor = .secondaryLabelColor
            scLabel.alignment = .right
            scLabel.lineBreakMode = .byTruncatingTail
            scLabel.frame = NSRect(x: rightEdge - scW, y: (rowH - 16) / 2, width: scW, height: 16)
            cell.addSubview(scLabel)
            rightEdge -= scW + 12
        }

        // Leading content starts at the shared edge inset; an app/file icon
        // (command palette / window switcher) shifts the text right when present.
        var x: CGFloat = E
        if let token = e.iconToken, let icon = ChooserPanel.icon(for: token) {
            let iv = NSImageView(frame: NSRect(x: x, y: (rowH - 32) / 2, width: 32, height: 32))
            iv.image = icon
            iv.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iv)
            x += 40   // 32px icon + 8px gap
        }
        let textW = max(40, rightEdge - 10 - x)

        let title = NSTextField(labelWithString: e.text)
        title.font = .systemFont(ofSize: 14)
        title.textColor = e.valid ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail

        if hasSub {
            // Stacked: title on the upper line gets the full row width before
            // truncating; the source sits on its own dim line beneath it (no
            // longer fighting the title for the same horizontal space).
            let titleH: CGFloat = 18, subH: CGFloat = 15, gap: CGFloat = 1
            let block = titleH + gap + subH
            let topPad = (rowH - block) / 2
            title.frame = NSRect(x: x, y: rowH - topPad - titleH, width: textW, height: titleH)
            cell.addSubview(title)

            let subLabel = NSTextField(labelWithString: e.subText ?? "")
            subLabel.font = .systemFont(ofSize: 12)
            subLabel.textColor = .tertiaryLabelColor
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: x, y: rowH - topPad - titleH - gap - subH, width: textW, height: subH)
            cell.addSubview(subLabel)
        } else {
            title.frame = NSRect(x: x, y: (rowH - 18) / 2, width: textW, height: 18)
            cell.addSubview(title)
        }
        return cell
    }

    /// A small rounded key-cap chip (e.g. "⌘1"), readable on the vibrant menu
    /// material in both light and dark appearance.
    private static func keycap(_ text: String) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: keycapWidth, height: keycapHeight))
        v.wantsLayer = true
        v.layer?.cornerRadius = 5
        v.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.16).cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.gray.withAlphaComponent(0.32).cgColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.frame = NSRect(x: 0, y: (keycapHeight - 14) / 2 - 0.5, width: keycapWidth, height: 14)
        v.addSubview(l)
        return v
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, entries[filtered[row]].valid else { return }
        finish(filtered[row] + 1)
    }

    // MARK: search field events

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            let row = selectedRow()
            if row > 0 { select(row) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil); return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        var row = (tableView.selectedRow >= 0 ? tableView.selectedRow : -delta)
        for _ in 0..<filtered.count {
            row += delta
            if row < 0 { row = filtered.count - 1 }
            if row >= filtered.count { row = 0 }
            if entries[filtered[row]].valid {
                setSelectedRow(row + 1)
                return
            }
        }
    }

    static func icon(for token: String) -> NSImage? {
        if token.hasPrefix("appicon:") {
            let bundleID = String(token.dropFirst("appicon:".count))
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if token.hasPrefix("appiconpid:") {
            // Fallback for processes without a registered .app bundle (e.g. swift run).
            guard let pid = Int32(token.dropFirst("appiconpid:".count)) else { return nil }
            return NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        }
        if token.hasPrefix("file:") {
            // An image on disk (e.g. a cached favicon); nil when missing.
            return NSImage(contentsOfFile: String(token.dropFirst("file:".count)))
        }
        return nil
    }
}

/// Row view that draws an accent-tinted rounded selection pill instead of the
/// default system gray, matching the Spotlight/Raycast-style chooser. The tint
/// is translucent so the row's normal label colors stay readable in both
/// light and dark appearance (no text-color flip needed).
@MainActor
final class ChooserRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // 8pt outside the cell's content edge inset (18) -> pill hugs content evenly.
        let r = bounds.insetBy(dx: 10, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 0.34 : 0.22).setFill()
        path.fill()
    }
}
