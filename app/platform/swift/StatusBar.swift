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

    /// A context collapses into a quick-trigger submenu once it has this many
    /// enabled action-features (fewer stay inline). Six window features today;
    /// text / web fold the same way as they grow.
    private static let groupThreshold = 3

    init(store: SettingsStore,
         openHome: @escaping (HomeDestination) -> Void) {
        self.store = store
        self.openHome = openHome
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = NSImage(systemSymbolName: "hammer.fill",
                                     accessibilityDescription: AppInfo.displayName)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        // START SPARKLE AT LAUNCH, not lazily.
        //
        // `Updater.shared` is a lazy singleton and its init is what calls
        // SPUStandardUpdaterController(startingUpdater: true) -- the call that
        // schedules the background check loop. Every other reference to it lives
        // in menuNeedsUpdate, the Settings view, or the menu action, i.e. code that
        // only runs if the user opens something. Without this line a user who never
        // opens the menubar menu never starts the updater at all: SUEnableAutomaticChecks
        // in the Info.plist is inert and no check ever happens, with no symptom.
        _ = Updater.shared.isAvailable
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
            let it = triggerItem(feature: palette, action: action, title: palette.name)
            it.image = featureImage(palette)
            menu.addItem(it)
            menu.addItem(.separator())
            anyTrigger = true
        }

        // Quick triggers, grouped by CONTEXT. A context that forms a real cluster
        // (window / text / web -- NOT the "anywhere" catch-all) collapses into a
        // submenu once it has `groupThreshold`+ enabled action-features, so the top
        // level stays short as the catalog grows; sparser contexts and the
        // "anywhere" features stay inline. Data-driven off the manifest `context`
        // field -- the SAME axis the Gallery/Tour group by (FeatureContext) -- so a
        // new feature slots into its group with no menu code. Command Palette is
        // excluded (pinned above).
        let triggerFeatures = store.features.filter {
            $0.enabled && !$0.actions.isEmpty && $0.id != "command_palette"
        }
        if !triggerFeatures.isEmpty { anyTrigger = true }

        var contextCount: [FeatureContext: Int] = [:]
        for f in triggerFeatures { contextCount[FeatureContext(f.context), default: 0] += 1 }
        func folds(_ c: FeatureContext) -> Bool {
            c != .anywhere && (contextCount[c] ?? 0) >= Self.groupThreshold
        }

        // Top-level entries: one submenu per folded context (its features nested
        // inside, each keeping its own single-row / sub-submenu shape), plus an
        // inline item for every ungrouped feature. Sorted by display title so the
        // order stays stable and alphabetical -- a folded group sorts by its context
        // title (e.g. "Windows"), landing right where its features used to.
        var entries: [(title: String, item: NSMenuItem)] = []
        var built: Set<FeatureContext> = []
        for feature in triggerFeatures {
            let c = FeatureContext(feature.context)
            if folds(c) {
                guard built.insert(c).inserted else { continue }   // one submenu per context
                let parent = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
                parent.image = contextImage(c)
                let sub = NSMenu()
                for gf in triggerFeatures where FeatureContext(gf.context) == c {
                    sub.addItem(featureMenuItem(gf))
                }
                parent.submenu = sub
                entries.append((c.title, parent))
            } else {
                entries.append((feature.name, featureMenuItem(feature)))
            }
        }
        entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        for e in entries { menu.addItem(e.item) }
        if !anyTrigger {
            let hint = NSMenuItem(title: Strings.t("menu.noTriggers", default: "No triggerable features enabled"),
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        // Primary destinations -- the two most-used. Home opens the Homepage
        // window (whose tabs cover the rest: Gallery / Shortcut Map / Timeline /
        // Settings), so the menu only needs the front door plus a direct Settings
        // jump; the other tabs + low-frequency utilities live under "More".
        let home = NSMenuItem(title: String(format: Strings.t("menu.open", default: "Open %@…"), AppInfo.displayName), action: #selector(showHome), keyEquivalent: "h")
        home.target = self
        home.toolTip = String(format: Strings.t("menu.open.tip", default: "Open %@: dashboard, gallery, shortcut map, timeline, and settings (switch tabs inside)"), AppInfo.displayName)
        menu.addItem(home)

        // Rules sits just above Settings: it's the other thing you open to
        // CONFIGURE the app (automations that fire on schedules / system events /
        // a display connecting), distinct from the per-feature Settings below it.
        let rules = NSMenuItem(title: Strings.t("menu.rules", default: "Rules…"), action: #selector(showRules),
                               keyEquivalent: "")
        rules.target = self
        rules.toolTip = Strings.t("menu.rules.tip", default: "Add and edit rules: run an automation when a schedule, system event, or display change fires")
        menu.addItem(rules)

        let settings = NSMenuItem(title: Strings.t("menu.settings", default: "Settings…"), action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        settings.toolTip = Strings.t("menu.settings.tip", default: "Enable/disable features, options, and trigger bindings")
        menu.addItem(settings)

        // Feature Pages: a feature that contributes a native page (e.g. usage_stats'
        // Usage Report) is a SERVICE with no actions, so it never shows in Quick
        // Triggers above and was reachable only via Open -> sidebar. Give each a direct
        // entry here. Data-driven (enabled + page-registered features), so a new
        // page-contributing feature appears with zero menu code.
        let pages = store.featurePages()
        if !pages.isEmpty {
            menu.addItem(.separator())
            for f in pages {
                let item = NSMenuItem(title: f.name + "…", action: #selector(showFeaturePage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = f.id
                menu.addItem(item)
            }
        }

        // "More": the other Homepage tabs plus rarely-touched utilities, tucked
        // into one submenu so the top level stays short.
        let more = NSMenuItem(title: Strings.t("menu.more", default: "More"), action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()

        let gallery = NSMenuItem(title: Strings.t("menu.gallery", default: "Feature Gallery…"), action: #selector(showGallery),
                                 keyEquivalent: "")
        gallery.target = self
        gallery.toolTip = String(format: Strings.t("menu.gallery.tip", default: "Browse everything %@ can do; enable features in place"), AppInfo.displayName)
        moreMenu.addItem(gallery)

        let shortcutMap = NSMenuItem(title: Strings.t("menu.shortcutMap", default: "Shortcut Map…"), action: #selector(showShortcutMap),
                                     keyEquivalent: "")
        shortcutMap.target = self
        shortcutMap.toolTip = Strings.t("menu.shortcutMap.tip", default: "See every shortcut at once, spot conflicts, and rebind in a grid")
        moreMenu.addItem(shortcutMap)

        let timeline = NSMenuItem(title: Strings.t("menu.timeline", default: "Automation Timeline…"), action: #selector(showTimeline),
                                  keyEquivalent: "")
        timeline.target = self
        timeline.toolTip = Strings.t("menu.timeline.tip", default: "See what's scheduled across the day -- times, intervals, and events")
        moreMenu.addItem(timeline)

        moreMenu.addItem(.separator())

        let reload = NSMenuItem(title: Strings.t("menu.reload", default: "Reload Features"), action: #selector(reloadFeatures),
                                keyEquivalent: "r")
        reload.target = self
        reload.toolTip = Strings.t("menu.reload.tip", default: "Re-read feature scripts from disk without restarting")
        moreMenu.addItem(reload)

        let logs = NSMenuItem(title: Strings.t("menu.logs", default: "Open Logs"), action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        logs.toolTip = Strings.t("menu.logs.tip", default: "Daily log files (troubleshooting clues live here)")
        moreMenu.addItem(logs)

        let report = NSMenuItem(title: Strings.t("menu.report", default: "Report a Problem…"),
                                action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        report.toolTip = Strings.t("menu.report.tip", default: "Email us with your version, macOS, permissions and enabled features filled in -- the details that make a report reproducible")
        moreMenu.addItem(report)

        // Only a packaged build can update itself: a dev `swift run` has no
        // SUFeedURL, so Updater has no controller and the item would do nothing.
        // Hidden rather than disabled -- a permanently greyed row in every dev
        // session reads as broken, not as inapplicable.
        if Updater.shared.isAvailable {
            let updates = NSMenuItem(title: Strings.t("menu.checkUpdates", default: "Check for Updates…"),
                                     action: #selector(checkForUpdates), keyEquivalent: "")
            updates.target = self
            // No `isEnabled` here: NSMenu.autoenablesItems defaults to true and is
            // never turned off in this tree, so AppKit recomputes enablement from
            // target/action at display time and would discard whatever we set.
            // Sparkle refuses a second concurrent check on its own anyway.
            updates.toolTip = String(format: Strings.t("menu.checkUpdates.tip", default: "Look for a newer %@ now; updates are signed and verified before they install"), AppInfo.displayName)
            moreMenu.addItem(updates)
        }

        moreMenu.addItem(.separator())

        let dock = NSMenuItem(title: Strings.t("menu.showInDock", default: "Show in Dock"), action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = DockPreference.showInDock ? .on : .off
        dock.toolTip = String(format: Strings.t("menu.showInDock.tip", default: "Keep a %@ icon in the Dock; click it to open Home"), AppInfo.displayName)
        moreMenu.addItem(dock)

        let capsHyper = NSMenuItem(title: Strings.t("menu.capsHyper", default: "Caps Lock acts as Hyper (⌘⌥⌃)"),
                                   action: #selector(toggleCapsHyper), keyEquivalent: "")
        capsHyper.target = self
        capsHyper.state = CapsHyperPreference.enabled ? .on : .off
        capsHyper.toolTip = Strings.t("menu.capsHyper.tip", default: "Hold Caps Lock as the ⌘⌥⌃ Hyper modifier so Hyper shortcuts are one key; double-tap Caps for its normal lock (remaps Caps; needs Accessibility)")
        moreMenu.addItem(capsHyper)

        more.submenu = moreMenu
        menu.addItem(more)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(format: Strings.t("menu.quit", default: "Quit %@"), AppInfo.displayName), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// A menu-sized, template SF Symbol image for a feature's glyph, so each
    /// quick-trigger row is scannable at a glance. Template rendering makes it
    /// track the menu's light/dark + selection highlight like native items do.
    private func featureImage(_ feature: FeatureInfo) -> NSImage? {
        let img = NSImage(systemSymbolName: featureIcon(feature), accessibilityDescription: nil)
        img?.isTemplate = true
        return img?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// The glyph for one action row in a multi-action submenu: its own declared
    /// icon, else the feature glyph -- the same resolution the command palette
    /// uses, so an action's icon matches across surfaces.
    private func actionImage(_ feature: FeatureInfo, _ action: ActionInfo) -> NSImage? {
        let img = NSImage(systemSymbolName: action.icon ?? featureIcon(feature),
                          accessibilityDescription: nil)
        img?.isTemplate = true
        return img?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// Template image for a context-group submenu -- mirrors featureImage but uses
    /// the FeatureContext glyph (e.g. "macwindow" for Windows).
    private func contextImage(_ context: FeatureContext) -> NSImage? {
        let img = NSImage(systemSymbolName: context.icon, accessibilityDescription: nil)
        img?.isTemplate = true
        return img?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// The quick-trigger menu item for one feature: a single row (its hotkey shown
    /// flush-right) for a one-action feature, or a submenu of its actions --
    /// built-ins first, then any DYNAMIC (user-saved, e.g. window_snap's saved
    /// placements) below a separator so they read as "yours". Used both inline at
    /// the top level and nested inside a context group.
    private func featureMenuItem(_ feature: FeatureInfo) -> NSMenuItem {
        if feature.actions.count == 1, let action = feature.actions.first {
            // triggerItem already sets the glyph (action icon -> feature icon);
            // don't override with the feature glyph or a single-action feature's
            // own per-action icon would be dropped here but honored in the palette.
            return triggerItem(feature: feature, action: action, title: feature.name)
        }
        let parent = NSMenuItem(title: feature.name, action: nil, keyEquivalent: "")
        parent.image = featureImage(feature)
        let sub = NSMenu()
        for action in feature.actions where !action.dynamic {
            sub.addItem(triggerItem(feature: feature, action: action, title: action.label))
        }
        let saved = feature.actions.filter { $0.dynamic }
        if !saved.isEmpty {
            // Separate saved from built-ins only when both exist -- a feature with
            // ONLY dynamic actions must not get a leading separator.
            if !sub.items.isEmpty { sub.addItem(.separator()) }
            for action in saved {
                sub.addItem(triggerItem(feature: feature, action: action, title: action.label))
            }
        }
        parent.submenu = sub
        return parent
    }

    private func triggerItem(feature: FeatureInfo, action: ActionInfo,
                             title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = [feature.id, action.id]
        // Leading glyph so a multi-action submenu is scannable (single-action
        // rows re-set the feature glyph in featureMenuItem, same result).
        mi.image = actionImage(feature, action)
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
            mi.toolTip = Strings.t("menu.runOnDemand.tip", default: "Runs on demand — bind a shortcut in Settings")
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

    @objc private func showFeaturePage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openHome(.feature(id))
    }

    @objc private func showRules() {
        openHome(.rules)
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

    /// Open a pre-filled mail with the diagnostics already in the body.
    ///
    /// The report also goes to the clipboard: a mailto body is length-limited and
    /// some mail clients mangle long ones, so the user always has an intact copy
    /// to paste even if the compose window arrives truncated or empty. Losing the
    /// details is the exact failure this feature exists to prevent, so it does not
    /// rely on the mailto surviving.
    @objc private func reportProblem() {
        let body = Diagnostics.report(store)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let subject = "\(AppInfo.displayName) \(version ?? "dev") -- "
        let intro = Strings.t("report.intro",
                              default: "Describe what you did and what you expected. Technical details "
                              + "below (also copied to your clipboard). The daily log is often the "
                              + "missing piece -- attach it from \"Open Logs\" if you can.")
        let full = intro + "\n\n---\n" + body

        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = Self.feedbackEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: full),
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where problem reports go. Plus-addressed per app, matching the studio
    /// convention in every sibling repo's .meta/feedback.json -- which is what
    /// lets the existing ingestion label them and file them as issues.
    private static let feedbackEmail = "studio.peach.go+hammerdeck@gmail.com"

    @objc private func checkForUpdates() {
        // Sparkle's own UI takes over from here (found / up-to-date / error), so
        // there is nothing to report back. Activate first: a menubar app is often
        // an accessory with no Dock tile, and Sparkle's window would otherwise
        // open behind whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.checkForUpdates()
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
            w.title = AppInfo.displayName
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

