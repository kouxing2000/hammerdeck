import AppKit
import SwiftUI

// Menubar presence: the hammer icon is a QUICK TRIGGER launcher -- every
// action of every ENABLED feature can be fired from here (including dormant
// actions with no hotkey bound). Enabling/disabling features lives in
// Settings, not the menu. Built with NSStatusItem (no SwiftUI App lifecycle
// conversion needed -- main.swift keeps NSApplication.run()).

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate, NSApplicationDelegate {
    private let item: NSStatusItem
    private let store: SettingsStore
    private let openHome: (HomeDestination) -> Void

    init(store: SettingsStore,
         openHome: @escaping (HomeDestination) -> Void) {
        self.store = store
        self.openHome = openHome
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

        // Primary destinations -- the two most-used. Home opens the Homepage
        // window (whose tabs cover the rest: Gallery / Shortcut Map / Timeline /
        // Settings), so the menu only needs the front door plus a direct Settings
        // jump; the other tabs + low-frequency utilities live under "More".
        let home = NSMenuItem(title: "Open Hammerdeck…", action: #selector(showHome), keyEquivalent: "h")
        home.target = self
        home.toolTip = "Open Hammerdeck: dashboard, gallery, shortcut map, timeline, and settings (switch tabs inside)"
        menu.addItem(home)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Enable/disable features, options, and trigger bindings"
        menu.addItem(settings)

        // "More": the other Homepage tabs plus rarely-touched utilities, tucked
        // into one submenu so the top level stays short.
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()

        let gallery = NSMenuItem(title: "Feature Gallery…", action: #selector(showGallery),
                                 keyEquivalent: "")
        gallery.target = self
        gallery.toolTip = "Browse everything Hammerdeck can do; enable features in place"
        moreMenu.addItem(gallery)

        let shortcutMap = NSMenuItem(title: "Shortcut Map…", action: #selector(showShortcutMap),
                                     keyEquivalent: "")
        shortcutMap.target = self
        shortcutMap.toolTip = "See every shortcut at once, spot conflicts, and rebind in a grid"
        moreMenu.addItem(shortcutMap)

        let timeline = NSMenuItem(title: "Automation Timeline…", action: #selector(showTimeline),
                                  keyEquivalent: "")
        timeline.target = self
        timeline.toolTip = "See what's scheduled across the day -- times, intervals, and events"
        moreMenu.addItem(timeline)

        moreMenu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Features", action: #selector(reloadFeatures),
                                keyEquivalent: "r")
        reload.target = self
        reload.toolTip = "Re-read feature scripts from disk without restarting"
        moreMenu.addItem(reload)

        let logs = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        logs.toolTip = "Daily log files (troubleshooting clues live here)"
        moreMenu.addItem(logs)

        moreMenu.addItem(.separator())

        let dock = NSMenuItem(title: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = DockPreference.showInDock ? .on : .off
        dock.toolTip = "Keep a Hammerdeck icon in the Dock; click it to open Home"
        moreMenu.addItem(dock)

        let capsHyper = NSMenuItem(title: "Caps Lock acts as Hyper (⌘⌥⌃)",
                                   action: #selector(toggleCapsHyper), keyEquivalent: "")
        capsHyper.target = self
        capsHyper.state = CapsHyperPreference.enabled ? .on : .off
        capsHyper.toolTip = "Hold Caps Lock as the ⌘⌥⌃ Hyper modifier so Hyper "
            + "shortcuts are one key; double-tap Caps for its normal lock "
            + "(remaps Caps; needs Accessibility)"
        moreMenu.addItem(capsHyper)

        more.submenu = moreMenu
        menu.addItem(more)

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
        // single source of truth (no double-trigger). Only a single-key "hotkey"
        // maps to that native column; a chord/schedule/event (or a hotkey whose
        // key has no single-char form) has no key-equivalent, so we render its
        // compact glyph (e.g. "⌃⌥⌘C C", "every 30m") as a dim INLINE suffix --
        // an attributedTitle can't reach the flush-right column (see the StatusBar
        // note in the layer map), but it stops a bound action from looking unbound.
        if let t = action.trigger, t.type == "hotkey", let ke = Self.keyEquivalent(for: t.key) {
            mi.keyEquivalent = ke
            mi.keyEquivalentModifierMask = Self.modifierMask(t.mods)
        } else if let t = action.trigger, case let glyph = shortcutGlyph(t), !glyph.isEmpty {
            mi.attributedTitle = Self.titleWithHint(title, hint: glyph)
        } else if action.trigger == nil {
            mi.toolTip = "Runs on demand — bind a shortcut in Settings"
        }
        return mi
    }

    /// Title + a dim, trailing shortcut glyph for triggers with no native
    /// key-equivalent (chords, schedules, events). secondaryLabelColor stays
    /// legible on the blue highlight too (an attributedTitle's colors don't
    /// auto-invert the way a native key-equivalent's do).
    private static func titleWithHint(_ title: String, hint: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        s.append(NSAttributedString(string: "   " + hint, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return s
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
        openHome(.settings)
    }

    @objc private func showHome() {
        openHome(.home)
    }

    @objc private func showShortcutMap() {
        openHome(.shortcuts)
    }

    @objc private func showTimeline() {
        openHome(.timeline)
    }

    @objc private func showGallery() {
        openHome(.features)
    }

    @objc private func reloadFeatures() {
        store.reload()
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Native.logsDir,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Native.logsDir)
    }

    @objc private func toggleDock() {
        DockPreference.set(!DockPreference.showInDock)
        DockPreference.apply()
    }

    @objc private func toggleCapsHyper() {
        CapsHyperPreference.userToggle(to: !CapsHyperPreference.enabled)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: app delegate

    /// Clicking the Dock icon (only present when "Show in Dock" is on) with no
    /// window up reopens the Homepage -- the reason to have the icon at all.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openHome(.home) }
        return true
    }
}

/// Lazily-created Homepage window: the shell that docks the Dashboard +
/// Gallery / Shortcut Map / Timeline / Settings tabs. `show(_:)` selects a tab
/// so the menubar can route straight to it (including straight to Settings).
@MainActor
final class HomepageWindow {
    private var window: NSWindow?
    private let store: SettingsStore
    private let nav = HomeNav()

    init(store: SettingsStore) {
        self.store = store
    }

    func show(_ destination: HomeDestination = .home) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: HomepageView(store: store, nav: nav)))
            w.title = "Hammerdeck"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 980, height: 620))
            w.center()
            window = w
        }
        nav.destination = destination
        store.refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// First-run onboarding: open the window on the Gallery (so dismissing the
    /// tour reveals whatever the user added) with the Feature Tour sheet up.
    func presentTour() {
        show(.features)
        nav.showTour = true
    }
}

