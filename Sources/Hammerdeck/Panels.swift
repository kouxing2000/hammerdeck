import AppKit

// Self-owned UI surfaces for the native backend. We deliberately do NOT use
// UserNotifications here: it requires an app bundle + a permission prompt, and
// the M2 host is a bare SwiftPM executable. Our own floating panels need zero
// permissions and match the platform's overlay use cases (banner countdown,
// chooser dialogs). Revisit real Notification Center delivery in M3 when there
// is a signed .app bundle.

/// A borderless floating panel that can become key without activating the app
/// (so the chooser can take keystrokes while the user's app keeps focus).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Toast (notify / alert)

@MainActor
enum Toast {
    private static var panels: [NSPanel] = []

    /// notify-style: top-right card with title + text. alert-style: centered.
    static func show(title: String?, text: String, centered: Bool, seconds: TimeInterval) {
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 360
        let pad: CGFloat = 14
        var y: CGFloat = pad

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10

        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 13)
        body.frame = NSRect(x: pad, y: pad, width: width - 2 * pad, height: 0)
        body.preferredMaxLayoutWidth = width - 2 * pad
        body.sizeToFit()
        y += body.frame.height
        content.addSubview(body)

        if let title, !title.isEmpty {
            y += 4
            let head = NSTextField(labelWithString: title)
            head.font = .boldSystemFont(ofSize: 13)
            head.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 18)
            content.addSubview(head)
            y += 18
        }
        y += pad

        let size = NSSize(width: width, height: y)
        let origin: NSPoint
        if centered {
            origin = NSPoint(x: screen.visibleFrame.midX - width / 2,
                             y: screen.visibleFrame.midY + 120)
        } else {
            origin = NSPoint(x: screen.visibleFrame.maxX - width - 16,
                             y: screen.visibleFrame.maxY - size.height - 16)
        }

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.ignoresMouseEvents = true
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.orderFrontRegardless()
        panels.append(panel)

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panels.removeAll { $0 === panel }
            }
        }
    }
}

// MARK: - Banner (full-width top overlay, e.g. sleep countdown)

@MainActor
final class BannerPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init(text: String) {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height: CGFloat = 44
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)

        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 0.85).cgColor

        label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 10, width: rect.width, height: 26)
        label.autoresizingMask = [.width]
        content.addSubview(label)

        panel.contentView = content
        panel.orderFrontRegardless()
    }

    func setText(_ text: String) { label.stringValue = text }

    func close() { panel.orderOut(nil) }
}

// MARK: - Progress strip (thin bar across the bottom of the main screen)

/// CountDown-style progress indicator: a few-pixel strip pinned to the bottom
/// edge -- elapsed portion red, remaining portion green (donor parity).
@MainActor
final class ProgressPanel {
    private let panel: NSPanel
    private let elapsedView = NSView()
    private let remainingView = NSView()
    private static let height: CGFloat = 5

    init() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.minX, y: screen.minY,
                          width: screen.width, height: ProgressPanel.height)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.75
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))
        elapsedView.wantsLayer = true
        elapsedView.layer?.backgroundColor = NSColor.systemRed.cgColor
        remainingView.wantsLayer = true
        remainingView.layer?.backgroundColor = NSColor.systemGreen.cgColor
        content.addSubview(elapsedView)
        content.addSubview(remainingView)
        panel.contentView = content
        panel.orderFrontRegardless()
        setProgress(0)
    }

    func setProgress(_ fraction: Double) {
        let f = CGFloat(max(0, min(1, fraction)))
        let w = panel.frame.width
        elapsedView.frame = NSRect(x: 0, y: 0, width: w * f, height: ProgressPanel.height)
        remainingView.frame = NSRect(x: w * f, y: 0, width: w * (1 - f), height: ProgressPanel.height)
    }

    func close() { panel.orderOut(nil) }
}

// MARK: - AskText (one-shot floating text prompt)

/// A floating single-line text prompt: Enter submits the text, Escape cancels
/// (submit nil). Mirrors the chooser's keyable-without-activating behavior.
@MainActor
final class AskTextPanel: NSObject, NSTextFieldDelegate {
    private let panel: KeyablePanel
    private let field = NSTextField()
    private let onSubmit: (String?) -> Void
    private var done = false

    init(title: String, placeholder: String, defaultValue: String,
         onSubmit: @escaping (String?) -> Void) {
        self.onSubmit = onSubmit
        let width: CGFloat = 420
        let height: CGFloat = 92
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let head = NSTextField(labelWithString: title)
        head.font = .boldSystemFont(ofSize: 14)
        head.frame = NSRect(x: 16, y: height - 32, width: width - 32, height: 18)
        content.addSubview(head)

        field.placeholderString = placeholder
        field.stringValue = defaultValue
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 16, y: 18, width: width - 32, height: 28)
        content.addSubview(field)

        panel.contentView = content
        panel.center()
        if let screen = NSScreen.main {
            var f = panel.frame
            f.origin.y = screen.visibleFrame.midY + 80
            panel.setFrame(f, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish(field.stringValue); return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil); return true
        default:
            return false
        }
    }

    /// Programmatic cancel that still fires onSubmit(nil) (dismiss semantics).
    func dismiss() { finish(nil) }

    /// Silent close (stop semantics): no callback.
    func close() {
        done = true
        panel.orderOut(nil)
    }

    private func finish(_ text: String?) {
        guard !done else { return }
        done = true
        panel.orderOut(nil)
        onSubmit(text)
    }
}

// MARK: - Chooser (searchable picker; also backs askChoice dialogs)

struct ChooserEntry {
    let text: String
    let subText: String?
    let iconToken: String?   // "appicon:<bundleID>"
    let valid: Bool          // false = info row, not selectable
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

    private static let width: CGFloat = 560
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
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        onHide()
    }

    var isVisible: Bool { panel.isVisible }

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
        panel.orderOut(nil)
    }

    // MARK: internals

    private func finish(_ originalIndex: Int?) {
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
        var x: CGFloat = 8

        if let token = e.iconToken, let icon = ChooserPanel.icon(for: token) {
            let iv = NSImageView(frame: NSRect(x: x, y: 5, width: 24, height: 24))
            iv.image = icon
            cell.addSubview(iv)
        }
        x += 32

        let title = NSTextField(labelWithString: e.text)
        title.font = .systemFont(ofSize: 14)
        title.textColor = e.valid ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: x, y: 8, width: ChooserPanel.width - x - 180, height: 18)
        cell.addSubview(title)

        if let sub = e.subText, !sub.isEmpty {
            let subLabel = NSTextField(labelWithString: sub)
            subLabel.font = .systemFont(ofSize: 11)
            subLabel.textColor = .secondaryLabelColor
            subLabel.alignment = .right
            subLabel.lineBreakMode = .byTruncatingTail
            subLabel.frame = NSRect(x: ChooserPanel.width - 188, y: 9, width: 160, height: 16)
            cell.addSubview(subLabel)
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
        guard token.hasPrefix("appicon:") else { return nil }
        let bundleID = String(token.dropFirst("appicon:".count))
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
