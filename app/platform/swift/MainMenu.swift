import AppKit

/// The main menu bar -- the one along the top of the screen, which Hammerdeck
/// owns whenever it is frontmost.
///
/// **The Edit menu is the load-bearing part, not About.** AppKit's
/// `StandardKeyBinding.dict` binds no `cut:` / `copy:` / `paste:` / `selectAll:`,
/// so those Cmd keys are delivered by an Edit menu's key equivalents and by
/// nothing else. An app with no main menu therefore has no working Cmd-V in any
/// of its text fields -- the API-key field, the Gallery search box, AskTextPanel,
/// the site and alias editors. That is why this file exists at all; the About
/// item and the version it shows are the visible half of a bigger hole.
///
/// **Every item is nil-target, dispatched down the responder chain.** The
/// app-specific ones land on `StatusBarController` because it is the app
/// delegate (see `Boot.swift`), which sits at the tail of the menu responder
/// chain -- so "open Settings" has one implementation, not two. The standard
/// actions (`terminate:`, `copy:`, `performZoom:`, ...) are nil-target by
/// definition: handing them an explicit target breaks the automatic enablement
/// that decides when AppKit greys them out, which is the whole reason a text
/// action knows it has nothing to cut.
///
/// Note what is and is not reachable under `.accessory` (Show in Dock off): the
/// BAR is never drawn, but its KEY EQUIVALENTS still dispatch whenever one of our
/// windows is key -- which is why the Edit menu repairs Cmd-V in menubar-only mode
/// too. Only the clickable items go away, so this cannot be the only home for the
/// version; the Homepage sidebar carries that unconditionally.
@MainActor
enum MainMenu {

    /// Build the bar and hand AppKit the three menus it populates itself.
    static func install(into app: NSApplication) {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu(), titled: AppInfo.displayName))
        bar.addItem(submenu(editMenu(), titled: Strings.t("mainmenu.edit", default: "Edit")))

        let windows = windowMenu()
        bar.addItem(submenu(windows, titled: Strings.t("mainmenu.window", default: "Window")))
        // AppKit adds and removes a row per open window in whichever menu this
        // points at. Without it the Window menu lists actions and never windows.
        app.windowsMenu = windows

        app.mainMenu = bar

        // NSApplication.h, `helpMenu`: "If a non-nil menu is set as the Help menu,
        // Spotlight for Help will be installed in it; otherwise AppKit will
        // install Spotlight for Help into a menu of its choosing... If you wish to
        // completely suppress Spotlight for Help, you can set a menu that does not
        // appear in the menu bar." Hammerdeck ships no help book, so that search
        // field would return nothing whatever it is attached to. This detached
        // menu is the documented way to say so.
        app.helpMenu = NSMenu()
    }

    // MARK: - The menus

    private static func appMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(format: Strings.t("mainmenu.about", default: "About %@"), AppInfo.displayName),
                       #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())

        // Same gate as the menulet's copy: a dev `swift run` has no SUFeedURL, so
        // Updater has no controller and the row would do nothing. Hidden rather
        // than permanently greyed -- a dead row reads as broken, not inapplicable.
        if Updater.shared.isAvailable {
            m.addItem(item(Strings.t("menu.checkUpdates", default: "Check for Updates…"),
                           #selector(StatusBarController.checkForUpdates)))
            m.addItem(.separator())
        }

        m.addItem(item(Strings.t("menu.settings", default: "Settings…"),
                       #selector(StatusBarController.showSettings), key: ","))
        m.addItem(item(Strings.t("menu.logs", default: "Open Logs"),
                       #selector(StatusBarController.openLogs)))
        m.addItem(item(Strings.t("menu.report", default: "Report a Problem…"),
                       #selector(StatusBarController.reportProblem)))
        m.addItem(.separator())

        let services = NSMenu()
        let servicesItem = NSMenuItem(title: Strings.t("mainmenu.services", default: "Services"),
                                      action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        m.addItem(servicesItem)
        // Populated entirely by AppKit from what the frontmost selection offers.
        NSApplication.shared.servicesMenu = services
        m.addItem(.separator())

        m.addItem(item(String(format: Strings.t("mainmenu.hide", default: "Hide %@"), AppInfo.displayName),
                       #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item(Strings.t("mainmenu.hideOthers", default: "Hide Others"),
                              #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        m.addItem(hideOthers)
        m.addItem(item(Strings.t("mainmenu.showAll", default: "Show All"),
                       #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())

        // `terminate:`, not StatusBarController.quit -- that method is literally
        // NSApp.terminate(nil), so routing through it would reimplement the
        // standard action and lose AppKit's enablement handling.
        m.addItem(item(String(format: Strings.t("menu.quit", default: "Quit %@"), AppInfo.displayName),
                       #selector(NSApplication.terminate(_:)), key: "q"))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(Strings.t("mainmenu.undo", default: "Undo"), Selector(("undo:")), key: "z"))
        let redo = item(Strings.t("mainmenu.redo", default: "Redo"), Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(redo)
        m.addItem(.separator())
        m.addItem(item(Strings.t("mainmenu.cut", default: "Cut"), #selector(NSText.cut(_:)), key: "x"))
        m.addItem(item(Strings.t("mainmenu.copy", default: "Copy"), #selector(NSText.copy(_:)), key: "c"))
        m.addItem(item(Strings.t("mainmenu.paste", default: "Paste"), #selector(NSText.paste(_:)), key: "v"))
        m.addItem(item(Strings.t("mainmenu.delete", default: "Delete"), #selector(NSText.delete(_:))))
        m.addItem(item(Strings.t("mainmenu.selectAll", default: "Select All"),
                       #selector(NSText.selectAll(_:)), key: "a"))
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu()
        // The owner's "show windows": the Homepage is closable, and once closed a
        // menubar app offers no obvious way back except the Dock icon, which is
        // itself optional.
        m.addItem(item(String(format: Strings.t("menu.open", default: "Open %@…"), AppInfo.displayName),
                       #selector(StatusBarController.showHome), key: "0"))
        m.addItem(.separator())
        // The Homepage is closable and Cmd-W is the reflex; without this item the
        // key equivalent resolves to nothing and the window just beeps.
        m.addItem(item(Strings.t("mainmenu.close", default: "Close"),
                       #selector(NSWindow.performClose(_:)), key: "w"))
        m.addItem(item(Strings.t("mainmenu.minimize", default: "Minimize"),
                       #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        m.addItem(item(Strings.t("mainmenu.zoom", default: "Zoom"),
                       #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item(Strings.t("mainmenu.bringAllToFront", default: "Bring All to Front"),
                       #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    // MARK: - Builders

    /// A nil-target item. No `isEnabled` is ever set here: `autoenablesItems`
    /// defaults to true, so AppKit recomputes enablement from the responder chain
    /// at display time and would discard anything set in advance.
    private static func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func submenu(_ menu: NSMenu, titled title: String) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        holder.submenu = menu
        return holder
    }
}
