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
    private let openShortcutMap: () -> Void
    private let openTimeline: () -> Void

    init(store: SettingsStore, openSettings: @escaping () -> Void,
         openShortcutMap: @escaping () -> Void,
         openTimeline: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.openShortcutMap = openShortcutMap
        self.openTimeline = openTimeline
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
        // A bound hotkey shows as a real, flush-right key-equivalent (display
        // only -- see menuHasKeyEquivalent); non-hotkey triggers show nothing.
        var anyTrigger = false

        // Pin the Command Palette at the very top -- the "run anything" launcher
        // over all the others, separated from the per-feature quick triggers.
        if let palette = store.features.first(where: {
            $0.id == "command_palette" && $0.enabled
        }), let action = palette.actions.first {
            menu.addItem(triggerItem(feature: palette, action: action, title: palette.name))
            menu.addItem(.separator())
            anyTrigger = true
        }

        for feature in store.features where feature.enabled && !feature.actions.isEmpty {
            if feature.id == "command_palette" { continue }   // pinned above
            anyTrigger = true
            if feature.actions.count == 1, let action = feature.actions.first {
                menu.addItem(triggerItem(feature: feature, action: action, title: feature.name))
            } else {
                let parent = NSMenuItem(title: feature.name, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for action in feature.actions {
                    sub.addItem(triggerItem(feature: feature, action: action, title: action.label))
                }
                parent.submenu = sub
                menu.addItem(parent)
            }
        }
        if !anyTrigger {
            let hint = NSMenuItem(title: "No triggerable features enabled",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        let shortcutMap = NSMenuItem(title: "Shortcut Map…", action: #selector(showShortcutMap),
                                     keyEquivalent: "")
        shortcutMap.target = self
        shortcutMap.toolTip = "See every shortcut at once, spot conflicts, and rebind in a grid"
        menu.addItem(shortcutMap)

        let timeline = NSMenuItem(title: "Automation Timeline…", action: #selector(showTimeline),
                                  keyEquivalent: "")
        timeline.target = self
        timeline.toolTip = "See what's scheduled across the day -- times, intervals, and events"
        menu.addItem(timeline)

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
        // Show a bound hotkey as a real key-equivalent so it sits flush-right in
        // the native shortcut column. It is DISPLAY ONLY: menuHasKeyEquivalent
        // refuses to fire any quick-trigger item, so the global hotkey stays the
        // single source of truth (no double-trigger). Only "hotkey" triggers map
        // to a single key-equivalent; chord/schedule/event have no key form and
        // show no hint (still click-to-run).
        if let t = action.trigger, t.type == "hotkey", let ke = Self.keyEquivalent(for: t.key) {
            mi.keyEquivalent = ke
            mi.keyEquivalentModifierMask = Self.modifierMask(t.mods)
        } else if action.trigger == nil {
            mi.toolTip = "Runs on demand — bind a shortcut in Settings"
        }
        return mi
    }

    // MARK: trigger -> native key-equivalent

    /// The key-equivalent character for a trigger key name, or nil when the key
    /// has no single-character form. Modifiers are carried separately.
    private static func keyEquivalent(for key: String) -> String? {
        switch key.lowercased() {
        case "space":               return " "
        case "tab":                 return "\t"
        case "return", "enter":     return "\r"
        case "delete", "backspace": return "\u{8}"
        case "escape", "esc":       return "\u{1b}"
        case "up":                  return String(UnicodeScalar(0xF700)!)
        case "down":                return String(UnicodeScalar(0xF701)!)
        case "left":                return String(UnicodeScalar(0xF702)!)
        case "right":               return String(UnicodeScalar(0xF703)!)
        default:                    return key.count == 1 ? key.lowercased() : nil
        }
    }

    private static func modifierMask(_ mods: [String]) -> NSEvent.ModifierFlags {
        let has = Set(mods.map { $0.lowercased() })
        var m: NSEvent.ModifierFlags = []
        if has.contains("ctrl") || has.contains("control") { m.insert(.control) }
        if has.contains("alt") || has.contains("option")   { m.insert(.option) }
        if has.contains("shift")                            { m.insert(.shift) }
        if has.contains("cmd") || has.contains("command")  { m.insert(.command) }
        return m
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        // A quick-trigger item shows its hotkey only as a flush-right hint. When
        // the user actually presses that hotkey -- even with the menu open -- the
        // global hotkey already runs the action, so ignore the menu's own
        // key-equivalent invocation to avoid a double-trigger. A real click
        // leaves a mouse event as currentEvent; a key-equivalent leaves a
        // keyboard one (keyDown/keyUp/flagsChanged, depending on timing).
        if let t = NSApp.currentEvent?.type, t == .keyDown || t == .keyUp || t == .flagsChanged {
            return
        }
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        store.runAction(pair[0], pair[1])
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showShortcutMap() {
        openShortcutMap()
    }

    @objc private func showTimeline() {
        openTimeline()
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

/// Lazily-created Automation Timeline window hosting the SwiftUI ruler/agenda.
/// Closing hides it; reopening refreshes from the registry. Mirrors the others.
@MainActor
final class AutomationTimelineWindow {
    private var window: NSWindow?
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController:
                NSHostingController(rootView: AutomationTimelineView(store: store)))
            w.title = "Automation Timeline"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 760, height: 600))
            w.center()
            window = w
        }
        store.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Lazily-created Shortcut Map window hosting the SwiftUI grid. Closing hides
/// it; reopening refreshes from the registry. Mirrors SettingsWindow.
@MainActor
final class ShortcutMapWindow {
    private var window: NSWindow?
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ShortcutMapView(store: store)))
            w.title = "Shortcut Map"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 820, height: 540))
            w.center()
            window = w
        }
        store.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
