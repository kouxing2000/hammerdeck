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
        var anyTrigger = false
        for feature in store.features where feature.enabled && !feature.actions.isEmpty {
            anyTrigger = true
            if feature.actions.count == 1, let action = feature.actions.first {
                menu.addItem(triggerItem(feature: feature, action: action,
                                         title: feature.name))
            } else {
                let parent = NSMenuItem(title: feature.name, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for action in feature.actions {
                    sub.addItem(triggerItem(feature: feature, action: action,
                                            title: action.label))
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
        // The bound shortcut (or "no trigger") rides along as the tooltip.
        mi.toolTip = action.triggerDesc
        return mi
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
