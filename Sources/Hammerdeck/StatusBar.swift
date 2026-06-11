import AppKit
import SwiftUI

// Menubar presence (Milestone 3 slice): the hammer icon with quick feature
// toggles, Settings..., and Quit. Built with NSStatusItem (no SwiftUI App
// lifecycle conversion needed -- main.swift keeps NSApplication.run()).

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

    // Rebuilt every time the menu opens, so toggles reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.refresh()

        for feature in store.features {
            let mi = NSMenuItem(title: feature.name, action: #selector(toggleFeature(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.state = feature.enabled ? .on : .off
            mi.representedObject = feature.id
            mi.toolTip = feature.triggerDesc
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Hammerdeck", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let feature = store.features.first(where: { $0.id == id }) else { return }
        store.setEnabled(id, !feature.enabled)
    }

    @objc private func showSettings() {
        openSettings()
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
