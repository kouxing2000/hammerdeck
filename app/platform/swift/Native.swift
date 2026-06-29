import AppKit
import CLua

/// The native backend: builds the `native` Lua table that
/// `lua/platform/adapter.lua` targets. This file + the panels/hotkey helpers
/// are the macOS-API surface of the project (the Swift side of the seam).
///
/// Conventions:
/// - Every binding-creating call returns an integer resource id; `native.stop(id)`
///   cancels it. Lua-side, the adapter wraps ids into `{ stop = ... }` handles.
/// - Lua callbacks are pinned via registry refs (LuaState.makeRef) and released
///   on cancel -- the callback-lifetime problem is solved HERE, once.
/// - Everything runs on the main thread: Lua boots on main, timers are on the
///   main RunLoop, Carbon/notification/panel callbacks arrive on main.
@MainActor
final class Native {
    static let shared = Native()
    private init() {}

    private(set) var lua: LuaState!

    private var nextId: Int32 = 1
    var cancellers: [Int32: () -> Void] = [:]
    var banners: [Int32: BannerPanel] = [:]
    var windowModeHUDs: [Int32: WindowModeHUDPanel] = [:]
    var choosers: [Int32: ChooserPanel] = [:]
    var progresses: [Int32: ProgressPanel] = [:]
    var askTexts: [Int32: AskTextPanel] = [:]
    var widgets: [Int32: UsageWidgetPanel] = [:]
    var mouseLocator: MouseLocatorPanel?

    // Window listing cache (rebuilt each list_windows; used by Native+Windows).
    // The CGWindowID rides along so focus_window can target the exact window via
    // the SkyLight front-process API (0 when the window had no matching CG row,
    // e.g. minimized -- the app is still front-ordered, just not window-targeted).
    struct AXWindowRef { let element: AXUIElement; let wid: CGWindowID }
    var axWindowCache: [Int: AXWindowRef] = [:]
    var nextWindowId = 1

    func attach(_ lua: LuaState) { self.lua = lua }

    func allocId() -> Int32 {
        let id = nextId
        nextId += 1
        return id
    }

    func registerResource(_ cancel: @escaping () -> Void) -> Int32 {
        let id = allocId()
        cancellers[id] = cancel
        return id
    }

    func freeResource(_ id: Int32) {
        cancellers[id] = nil
        banners[id] = nil
        windowModeHUDs[id] = nil
        choosers[id] = nil
        progresses[id] = nil
        askTexts[id] = nil
        widgets[id] = nil
    }

    // MARK: - Table registration

    func installBindings() {
        // SwiftC cannot type-check one ~90-entry [String: @convention(c) closure]
        // literal in reasonable time -- split into smaller literals it can handle,
        // then merge. Keys are unique, so the conflict resolver is never hit.
        var fns: [String: LuaState.Function] = [
            // core
            "log":          { L in MainActor.assumeIsolated { Native.shared.log(L) } },
            "stop":         { L in MainActor.assumeIsolated { Native.shared.stop(L) } },
            // triggers
            "bind_hotkey":  { L in MainActor.assumeIsolated { Native.shared.bindHotkey(L) } },
            "bind_chord":   { L in MainActor.assumeIsolated { Native.shared.bindChord(L) } },
            "timer_every":  { L in MainActor.assumeIsolated { Native.shared.timerEvery(L) } },
            "timer_after":  { L in MainActor.assumeIsolated { Native.shared.timerAfter(L) } },
            "timer_daily_at": { L in MainActor.assumeIsolated { Native.shared.timerDailyAt(L) } },
            "on_system_event": { L in MainActor.assumeIsolated { Native.shared.onSystemEvent(L) } },
            // persistence
            "get_setting":  { L in MainActor.assumeIsolated { Native.shared.getSetting(L) } },
            "set_setting":  { L in MainActor.assumeIsolated { Native.shared.setSetting(L) } },
            // secrets (login Keychain -- never plaintext UserDefaults)
            "keychain_get":    { L in MainActor.assumeIsolated { Native.shared.keychainGet(L) } },
            "keychain_set":    { L in MainActor.assumeIsolated { Native.shared.keychainSet(L) } },
            "keychain_delete": { L in MainActor.assumeIsolated { Native.shared.keychainDelete(L) } },
            // clipboard (general pasteboard -- no permission required)
            "pasteboard_read":  { L in MainActor.assumeIsolated { Native.shared.pasteboardRead(L) } },
            "pasteboard_write": { L in MainActor.assumeIsolated { Native.shared.pasteboardWrite(L) } },
            "pasteboard_info":  { L in MainActor.assumeIsolated { Native.shared.pasteboardInfo(L) } },
            // output
            "notify":        { L in MainActor.assumeIsolated { Native.shared.notify(L) } },
            "system_notify": { L in MainActor.assumeIsolated { Native.shared.systemNotify(L) } },
            "alert":         { L in MainActor.assumeIsolated { Native.shared.alert(L) } },
            // banner
            "banner_show":  { L in MainActor.assumeIsolated { Native.shared.bannerShow(L) } },
            "banner_set_text": { L in MainActor.assumeIsolated { Native.shared.bannerSetText(L) } },
            "hud_show":     { L in MainActor.assumeIsolated { Native.shared.hudShow(L) } },
        ]
        let fns2: [String: LuaState.Function] = [
            // chooser / dialogs
            "chooser_new":  { L in MainActor.assumeIsolated { Native.shared.chooserNew(L) } },
            "chooser_set_choices": { L in MainActor.assumeIsolated { Native.shared.chooserSetChoices(L) } },
            "chooser_set_placeholder": { L in MainActor.assumeIsolated { Native.shared.chooserSetPlaceholder(L) } },
            "chooser_set_title": { L in MainActor.assumeIsolated { Native.shared.chooserSetTitle(L) } },
            "chooser_set_query": { L in MainActor.assumeIsolated { Native.shared.chooserSetQuery(L) } },
            "chooser_show": { L in MainActor.assumeIsolated { Native.shared.chooserShow(L) } },
            "chooser_hide": { L in MainActor.assumeIsolated { Native.shared.chooserHide(L) } },
            "chooser_visible": { L in MainActor.assumeIsolated { Native.shared.chooserVisible(L) } },
            "chooser_selected_row": { L in MainActor.assumeIsolated { Native.shared.chooserSelectedRow(L) } },
            "chooser_set_selected_row": { L in MainActor.assumeIsolated { Native.shared.chooserSetSelectedRow(L) } },
            "chooser_select": { L in MainActor.assumeIsolated { Native.shared.chooserSelect(L) } },
            "ask_choice":   { L in MainActor.assumeIsolated { Native.shared.askChoice(L) } },
            "ask_text":     { L in MainActor.assumeIsolated { Native.shared.askText(L) } },
            "ask_text_dismiss": { L in MainActor.assumeIsolated { Native.shared.askTextDismiss(L) } },
            "progress_show": { L in MainActor.assumeIsolated { Native.shared.progressShow(L) } },
            "progress_set":  { L in MainActor.assumeIsolated { Native.shared.progressSet(L) } },
            "usage_widget_show": { L in MainActor.assumeIsolated { Native.shared.usageWidgetShow(L) } },
            "usage_widget_set":  { L in MainActor.assumeIsolated { Native.shared.usageWidgetSet(L) } },
            "locate_mouse":  { L in MainActor.assumeIsolated { Native.shared.locateMouse(L) } },
            // network / files / wallpaper
            "http_get":      { L in MainActor.assumeIsolated { Native.shared.httpGet(L) } },
            "http_request":  { L in MainActor.assumeIsolated { Native.shared.httpRequest(L) } },
            "download_file": { L in MainActor.assumeIsolated { Native.shared.downloadFile(L) } },
            "set_wallpaper": { L in MainActor.assumeIsolated { Native.shared.setWallpaper(L) } },
            "set_wallpaper_color": { L in MainActor.assumeIsolated { Native.shared.setWallpaperColor(L) } },
            "cache_dir":     { L in MainActor.assumeIsolated { Native.shared.cacheDir(L) } },
            "ask_choice_dismiss": { L in MainActor.assumeIsolated { Native.shared.askChoiceDismiss(L) } },
        ]
        let fns3: [String: LuaState.Function] = [
            // windows / apps (AXUIElement -- needs the Accessibility permission)
            "list_windows": { L in MainActor.assumeIsolated { Native.shared.listWindows(L) } },
            "focus_window": { L in MainActor.assumeIsolated { Native.shared.focusWindow(L) } },
            "ax_trusted":   { L in MainActor.assumeIsolated { Native.shared.axTrusted(L) } },
            "ax_prompt":    { L in MainActor.assumeIsolated { Native.shared.axPrompt(L) } },
            "ax_open_settings": { L in MainActor.assumeIsolated { Native.shared.openAccessibilitySettings(L) } },
            "focused_window_frame": { L in MainActor.assumeIsolated { Native.shared.focusedWindowFrame(L) } },
            "focused_window_title": { L in MainActor.assumeIsolated { Native.shared.focusedWindowTitle(L) } },
            "set_focused_window_frame": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFrame(L) } },
            "set_window_frame": { L in MainActor.assumeIsolated { Native.shared.setWindowFrame(L) } },
            "appearance":    { L in MainActor.assumeIsolated { Native.shared.appearance(L) } },
            "set_appearance": { L in MainActor.assumeIsolated { Native.shared.setAppearance(L) } },
            "running_apps":  { L in MainActor.assumeIsolated { Native.shared.runningApps(L) } },
            "power_source":  { L in MainActor.assumeIsolated { Native.shared.powerSource(L) } },
            "set_focused_window_fullscreen": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFullscreen(L) } },
            "minimize_app":  { L in MainActor.assumeIsolated { Native.shared.minimizeApp(L) } },
            "hide_app":      { L in MainActor.assumeIsolated { Native.shared.hideApp(L) } },
            "quit_app":      { L in MainActor.assumeIsolated { Native.shared.quitApp(L) } },
            "screen_frames": { L in MainActor.assumeIsolated { Native.shared.screenFrames(L) } },
            "mouse_position": { L in MainActor.assumeIsolated { Native.shared.mousePosition(L) } },
            "set_mouse_position": { L in MainActor.assumeIsolated { Native.shared.setMousePosition(L) } },
            "app_icon":     { L in MainActor.assumeIsolated { Native.shared.appIcon(L) } },
            // platform: discover feature modules on disk
            "discover_features": { L in MainActor.assumeIsolated { Native.shared.discoverFeatures(L) } },
            // platform: the user's enabled macOS system shortcuts (read-only)
            "system_hotkeys": { L in MainActor.assumeIsolated { Native.shared.systemHotkeys(L) } },
            // app metadata: the user-visible display name (single source of truth)
            "app_name":     { L in MainActor.assumeIsolated { Native.shared.appName(L) } },
            // resolved UI locale code (shared with Lua via adapter.locale())
            "locale":       { L in MainActor.assumeIsolated { Native.shared.locale(L) } },
            // app focus tracking (NSWorkspace -- no permission required)
            "frontmost_app":    { L in MainActor.assumeIsolated { Native.shared.frontmostApp(L) } },
            "on_app_activated": { L in MainActor.assumeIsolated { Native.shared.onAppActivated(L) } },
        ]
        let fns4: [String: LuaState.Function] = [
            // data files (feature-owned storage under Application Support)
            "data_dir":         { L in MainActor.assumeIsolated { Native.shared.dataDir(L) } },
            "home_dir":         { L in MainActor.assumeIsolated { Native.shared.homeDir(L) } },
            "mkdir":            { L in MainActor.assumeIsolated { Native.shared.mkdir(L) } },
            "remove_subdir":    { L in MainActor.assumeIsolated { Native.shared.removeSubdir(L) } },
            // input synthesis (CGEvent posting -- needs Accessibility)
            "key_stroke":   { L in MainActor.assumeIsolated { Native.shared.keyStroke(L) } },
            "type_text":    { L in MainActor.assumeIsolated { Native.shared.typeText(L) } },
            // apps / urls
            "open_url":     { L in MainActor.assumeIsolated { Native.shared.openUrl(L) } },
            "activate_app": { L in MainActor.assumeIsolated { Native.shared.activateApp(L) } },
            "launch_or_focus_app": { L in MainActor.assumeIsolated { Native.shared.launchOrFocusApp(L) } },
            "focus_browser_tab": { L in MainActor.assumeIsolated { Native.shared.focusBrowserTab(L) } },
            "focus_safari_tab":  { L in MainActor.assumeIsolated { Native.shared.focusSafariTab(L) } },
            "open_site_app":     { L in MainActor.assumeIsolated { Native.shared.openSiteApp(L) } },
            "open_site":         { L in MainActor.assumeIsolated { Native.shared.openSite(L) } },
            "default_browser_bundle_id": { L in MainActor.assumeIsolated { Native.shared.defaultBrowserBundleId(L) } },
            "app_running":       { L in MainActor.assumeIsolated { Native.shared.appRunning(L) } },
            "browser_list_tabs": { L in MainActor.assumeIsolated { Native.shared.browserListTabs(L) } },
            "browser_focus_tab_at": { L in MainActor.assumeIsolated { Native.shared.browserFocusTabAt(L) } },
            "browser_active_url":   { L in MainActor.assumeIsolated { Native.shared.browserActiveUrl(L) } },
            "extract_favicons":     { L in MainActor.assumeIsolated { Native.shared.extractFavicons(L) } },
        ]
        let fns5: [String: LuaState.Function] = [
            // input / system
            "idle_seconds": { L in MainActor.assumeIsolated { Native.shared.idleSeconds(L) } },
            "random_int": { L in MainActor.assumeIsolated { Native.shared.randomInt(L) } },
            "is_modifier_held": { L in MainActor.assumeIsolated { Native.shared.isModifierHeld(L) } },
            "system_sleep": { L in MainActor.assumeIsolated { Native.shared.systemSleep(L) } },
            "lock_screen":  { L in MainActor.assumeIsolated { Native.shared.lockScreen(L) } },
            "run_shortcut": { L in MainActor.assumeIsolated { Native.shared.runShortcut(L) } },
            "display_sleep": { L in MainActor.assumeIsolated { Native.shared.displaySleep(L) } },
            "start_screensaver": { L in MainActor.assumeIsolated { Native.shared.startScreensaver(L) } },
            "say": { L in MainActor.assumeIsolated { Native.shared.speak(L) } },
            "adjust_volume": { L in MainActor.assumeIsolated { Native.shared.adjustVolume(L) } },
            "toggle_mute": { L in MainActor.assumeIsolated { Native.shared.toggleMute(L) } },
            "empty_trash": { L in MainActor.assumeIsolated { Native.shared.emptyTrash(L) } },
            "eject": { L in MainActor.assumeIsolated { Native.shared.eject(L) } },
        ]
        for chunk in [fns2, fns3, fns4, fns5] { fns.merge(chunk) { current, _ in current } }
        lua.registerTable("native", fns)
    }

    // MARK: - Core

    // Logging goes to stdout AND a daily file under Application Support/
    // Hammerdeck/logs/ -- stdout dies with the terminal; troubleshooting
    // needs durable clues (the donor's fileLogger lesson).
    private var logHandle: FileHandle?
    private var logDay = ""
    nonisolated static let logsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Hammerdeck/logs", isDirectory: true)
    }()

    func appendLogLine(_ msg: String) {
        let now = Date()
        let day = Native.dayFormatter.string(from: now)
        if logHandle == nil || day != logDay {
            logHandle?.closeFile()
            try? FileManager.default.createDirectory(at: Native.logsDir,
                                                     withIntermediateDirectories: true)
            let path = Native.logsDir.appendingPathComponent(day + ".log").path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            logHandle = FileHandle(forWritingAtPath: path)
            logHandle?.seekToEndOfFile()
            logDay = day
            Native.pruneOldLogs()   // retention rides the day rollover
        }
        let line = "[" + Native.timeFormatter.string(from: now) + "] " + msg + "\n"
        if let data = line.data(using: .utf8) { logHandle?.write(data) }
    }

    /// Keep the newest `keep` daily log files; logging is always-on (clues
    /// must exist BEFORE a bug is noticed), so retention is what bounds it.
    nonisolated static func pruneOldLogs(keep: Int = 14) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return }
        let logs = files.filter { $0.hasSuffix(".log") }.sorted()   // name order = date order
        guard logs.count > keep else { return }
        for f in logs.prefix(logs.count - keep) {
            try? fm.removeItem(at: logsDir.appendingPathComponent(f))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func log(_ L: OpaquePointer?) -> Int32 {
        let msg = LuaState.string(L, 1) ?? "(nil)"
        print("[hammerdeck]", msg)
        appendLogLine(msg)
        return 0
    }

    func stop(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let cancel = cancellers[id] {
            cancel()
            freeResource(id)
        }
        return 0
    }

    // MARK: - Errors

    func luaError(_ L: OpaquePointer?, _ message: String) -> Int32 {
        lua_pushstring(L, message)
        return lua_error(L)
    }
}
