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
final class ChooserPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel: KeyablePanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var entries: [ChooserEntry] = []
    private var filtered: [Int] = []     // indices into entries
    private let searchSubText: Bool
    private let onSelect: (Int?) -> Void
    private let onHide: () -> Void
    private var keyMonitor: Any?         // cmd+1..9 quick-pick, live while shown

    private static let width: CGFloat = 680
    private static let rowHeight: CGFloat = 34
    private static let searchHeight: CGFloat = 36

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

        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 18)
        searchField.delegate = self
        content.addSubview(searchField)

        tableView.headerView = nil
        tableView.rowHeight = ChooserPanel.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.addTableColumn(NSTableColumn(identifier: .init("main")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        content.addSubview(scrollView)

        panel.contentView = content
    }

    // MARK: public API (mirrors the adapter chooser handle)

    func setPlaceholder(_ text: String) {
        searchField.placeholderString = text
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
        removeQuickKeys()
        panel.orderOut(nil)
    }

    // MARK: internals

    private func finish(_ originalIndex: Int?) {
        removeQuickKeys()
        if panel.isVisible { panel.orderOut(nil) }
        onSelect(originalIndex)
        onHide()
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
        let rows = CGFloat(min(max(filtered.count, 1), 10))
        let listHeight = rows * ChooserPanel.rowHeight + 8
        let total = listHeight + ChooserPanel.searchHeight + 12
        var f = panel.frame
        let topY = f.maxY
        f.size = NSSize(width: ChooserPanel.width, height: total)
        f.origin.y = topY - total
        panel.setFrame(f, display: true)

        let content = panel.contentView!
        searchField.frame = NSRect(x: 16, y: total - ChooserPanel.searchHeight,
                                   width: ChooserPanel.width - 32, height: 26)
        scrollView.frame = NSRect(x: 4, y: 6, width: ChooserPanel.width - 8, height: listHeight)
        content.frame = NSRect(origin: .zero, size: f.size)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entries[filtered[row]].valid
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[filtered[row]]
        let cell = NSView()
        // Left gutter holds the quick-pick hint (cmd+1..9) for the first nine
        // SELECTABLE rows, so the keyboard shortcut is discoverable, not hidden.
        // Info rows (valid=false) get no hint -- cmd+N won't fire them.
        let gutter: CGFloat = 24
        if row < 9 && e.valid {
            let hint = NSTextField(labelWithString: "⌘\(row + 1)")
            hint.font = .systemFont(ofSize: 10, weight: .medium)
            hint.textColor = .tertiaryLabelColor
            hint.alignment = .center
            hint.frame = NSRect(x: 0, y: 10, width: gutter, height: 14)
            cell.addSubview(hint)
        }
        var x: CGFloat = gutter

        if let token = e.iconToken, let icon = ChooserPanel.icon(for: token) {
            let iv = NSImageView(frame: NSRect(x: x, y: 5, width: 24, height: 24))
            iv.image = icon
            cell.addSubview(iv)
        }
        x += 32

        // Three columns: title (flexible, left), source feature (dim context),
        // and the trigger/shortcut preview flush to the right edge. Each is its
        // own label so the shortcut stays right-aligned and never gets eaten by a
        // long feature name truncating ahead of it.
        // 28pt is the proven-safe right margin under the table's .inset style
        // (content past width-28 gets clipped by the inset).
        let rightMargin: CGFloat = 28
        let shortcutW: CGFloat = 100   // compact glyphs (⇧⌘V, every 180m)
        let shortcutX = ChooserPanel.width - rightMargin - shortcutW
        let sourceW: CGFloat = 150
        let sourceX = shortcutX - 12 - sourceW

        let title = NSTextField(labelWithString: e.text)
        title.font = .systemFont(ofSize: 14)
        title.textColor = e.valid ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: x, y: 8, width: sourceX - 12 - x, height: 18)
        cell.addSubview(title)

        if let sub = e.subText, !sub.isEmpty {
            let subLabel = NSTextField(labelWithString: sub)
            subLabel.font = .systemFont(ofSize: 11)
            subLabel.textColor = .tertiaryLabelColor
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: sourceX, y: 9, width: sourceW, height: 16)
            cell.addSubview(subLabel)
        }

        if let sc = e.shortcut, !sc.isEmpty {
            let scLabel = NSTextField(labelWithString: sc)
            scLabel.font = .systemFont(ofSize: 11)
            scLabel.textColor = .secondaryLabelColor
            scLabel.alignment = .right
            scLabel.lineBreakMode = .byTruncatingTail
            scLabel.frame = NSRect(x: shortcutX, y: 9, width: shortcutW, height: 16)
            cell.addSubview(scLabel)
        }
        return cell
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
        if token.hasPrefix("file:") {
            // An image on disk (e.g. a cached favicon); nil when missing.
            return NSImage(contentsOfFile: String(token.dropFirst("file:".count)))
        }
        return nil
    }
}
