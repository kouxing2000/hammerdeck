import AppKit
import SwiftUI

// Menubar presence: the hammer icon is a QUICK TRIGGER launcher -- every
// action of every ENABLED feature can be fired from here (including dormant
// actions with no hotkey bound). Enabling/disabling features lives in
// Settings, not the menu. Built with NSStatusItem (no SwiftUI App lifecycle
// conversion needed -- main.swift keeps NSApplication.run()).

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: SettingsStore
    private let openSettings: () -> Void

    init(store: SettingsStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = NSImage(systemSymbolName: "hammer.fill",
                                     accessibilityDescription: "Hammerdeck")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    // Rebuilt every time the menu opens, so it reflects the current catalog.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.refresh()

        // Quick triggers: one item per action of each enabled feature.
        // Single-action features get one row; multi-action features a submenu.
        // Each row shows its bound shortcut inline (right of the name); an
        // action with no shortcut shows nothing and is still click-to-run.
        var rows: [Row] = []
        var anyTrigger = false

        // Pin the Command Palette at the very top -- it is the "run anything"
        // launcher over all the others, so it reads as the primary entry,
        // separated from the per-feature quick triggers below.
        if let palette = store.features.first(where: {
            $0.id == "command_palette" && $0.enabled
        }), let action = palette.actions.first {
            let mi = triggerItem(feature: palette, action: action, title: palette.name)
            menu.addItem(mi)
            // Align on its own: it sits in its own section above the separator,
            // so its shortcut column must not be computed jointly with the
            // quick-trigger rows below it.
            alignShortcuts([Row(item: mi, label: palette.name, shortcut: shortcutText(action))])
            menu.addItem(.separator())
            anyTrigger = true
        }

        for feature in store.features where feature.enabled && !feature.actions.isEmpty {
            if feature.id == "command_palette" { continue }   // pinned above
            anyTrigger = true
            if feature.actions.count == 1, let action = feature.actions.first {
                let mi = triggerItem(feature: feature, action: action, title: feature.name)
                menu.addItem(mi)
                rows.append(Row(item: mi, label: feature.name, shortcut: shortcutText(action)))
            } else {
                let parent = NSMenuItem(title: feature.name, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                var subRows: [Row] = []
                for action in feature.actions {
                    let mi = triggerItem(feature: feature, action: action, title: action.label)
                    sub.addItem(mi)
                    subRows.append(Row(item: mi, label: action.label, shortcut: shortcutText(action)))
                }
                alignShortcuts(subRows)
                parent.submenu = sub
                menu.addItem(parent)
                rows.append(Row(item: parent, label: feature.name, shortcut: nil))
            }
        }
        alignShortcuts(rows)
        if !anyTrigger {
            let hint = NSMenuItem(title: "No triggerable features enabled",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Enable/disable features, options, and trigger bindings"
        menu.addItem(settings)

        let reload = NSMenuItem(title: "Reload Features", action: #selector(reloadFeatures),
                                keyEquivalent: "r")
        reload.target = self
        reload.toolTip = "Re-read feature scripts from disk without restarting"
        menu.addItem(reload)

        let logs = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        logs.toolTip = "Daily log files (troubleshooting clues live here)"
        menu.addItem(logs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Hammerdeck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func triggerItem(feature: FeatureInfo, action: ActionInfo,
                             title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = [feature.id, action.id]
        // The shortcut now shows inline (alignShortcuts). Only a no-shortcut
        // action needs a hint, so its bare row doesn't read as broken.
        if shortcutText(action) == nil {
            mi.toolTip = "Runs on demand — bind a shortcut in Settings"
        }
        return mi
    }

    // One menu row awaiting shortcut alignment.
    private struct Row { let item: NSMenuItem; let label: String; let shortcut: String? }

    private static let menuFont = NSFont.menuFont(ofSize: 0)

    /// Right-align the shortcut column for rows that share one menu: the
    /// shortcut starts at a tab stop just past the widest label, so the combos
    /// line up like a native menu. Display-only (attributedTitle, not a
    /// keyEquivalent), so it never double-fires the global hotkey.
    private func alignShortcuts(_ rows: [Row]) {
        let font = Self.menuFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var maxLabel: CGFloat = 0
        for r in rows where r.shortcut != nil {
            maxLabel = max(maxLabel, (r.label as NSString).size(withAttributes: attrs).width)
        }
        guard maxLabel > 0 else { return }   // nothing in this menu has a shortcut
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: maxLabel + 28)]
        for r in rows {
            guard let sc = r.shortcut else { continue }
            let title = NSMutableAttributedString(string: r.label, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
            ])
            title.append(NSAttributedString(string: "\t" + sc, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para,
            ]))
            r.item.attributedTitle = title
        }
    }

    // Apple-order modifier glyphs (⌃⌥⇧⌘) for a hotkey/chord's mods.
    private func modGlyphs(_ mods: [String]) -> String {
        let has = Set(mods.map { $0.lowercased() })
        var s = ""
        if has.contains("ctrl") || has.contains("control") { s += "⌃" }
        if has.contains("alt") || has.contains("option")   { s += "⌥" }
        if has.contains("shift")                            { s += "⇧" }
        if has.contains("cmd") || has.contains("command")  { s += "⌘" }
        return s
    }

    private func keyGlyph(_ key: String) -> String {
        switch key.lowercased() {
        case "tab":                 return "⇥"
        case "return", "enter":     return "↩"
        case "space":               return "␣"
        case "delete", "backspace": return "⌫"
        case "escape", "esc":       return "⎋"
        case "left":                return "←"
        case "right":               return "→"
        case "up":                  return "↑"
        case "down":                return "↓"
        default:                    return key.count == 1 ? key.uppercased() : key
        }
    }

    /// The inline label for an action's CURRENT trigger, or nil when it has
    /// none (a dormant, menu-only action).
    private func shortcutText(_ a: ActionInfo) -> String? {
        guard let t = a.trigger else { return nil }
        switch t.type {
        case "hotkey":
            return modGlyphs(t.mods) + keyGlyph(t.key)
        case "chord":
            let follows = t.follows.map(keyGlyph).joined(separator: " ")
            return modGlyphs(t.mods) + keyGlyph(t.key) + " " + follows
        case "schedule":
            if let m = t.everyMin { return "every \(m)m" }
            return "at \(t.at ?? "")"
        case "event":
            return "on \(t.event ?? "")"
        default:
            return nil
        }
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        store.runAction(pair[0], pair[1])
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func reloadFeatures() {
        store.reload()
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Native.logsDir,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Native.logsDir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Lazily-created settings window hosting the SwiftUI form. Closing hides it;
/// reopening refreshes from the registry.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = "Hammerdeck Settings"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 480))
            w.center()
            window = w
        }
        store.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
