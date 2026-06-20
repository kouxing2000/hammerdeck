import AppKit
import CLua
import SQLite3
import Security

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
    private var cancellers: [Int32: () -> Void] = [:]
    private var banners: [Int32: BannerPanel] = [:]
    private var choosers: [Int32: ChooserPanel] = [:]
    private var progresses: [Int32: ProgressPanel] = [:]
    private var askTexts: [Int32: AskTextPanel] = [:]
    private var widgets: [Int32: UsageWidgetPanel] = [:]
    private var mouseLocator: MouseLocatorPanel?

    func attach(_ lua: LuaState) { self.lua = lua }

    private func allocId() -> Int32 {
        let id = nextId
        nextId += 1
        return id
    }

    private func registerResource(_ cancel: @escaping () -> Void) -> Int32 {
        let id = allocId()
        cancellers[id] = cancel
        return id
    }

    private func freeResource(_ id: Int32) {
        cancellers[id] = nil
        banners[id] = nil
        choosers[id] = nil
        progresses[id] = nil
        askTexts[id] = nil
        widgets[id] = nil
    }

    // MARK: - Table registration

    func installBindings() {
        lua.registerTable("native", [
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
            // clipboard (general pasteboard -- no permission required)
            "pasteboard_read":  { L in MainActor.assumeIsolated { Native.shared.pasteboardRead(L) } },
            "pasteboard_write": { L in MainActor.assumeIsolated { Native.shared.pasteboardWrite(L) } },
            "pasteboard_info":  { L in MainActor.assumeIsolated { Native.shared.pasteboardInfo(L) } },
            // output
            "notify":       { L in MainActor.assumeIsolated { Native.shared.notify(L) } },
            "alert":        { L in MainActor.assumeIsolated { Native.shared.alert(L) } },
            // banner
            "banner_show":  { L in MainActor.assumeIsolated { Native.shared.bannerShow(L) } },
            "banner_set_text": { L in MainActor.assumeIsolated { Native.shared.bannerSetText(L) } },
            // chooser / dialogs
            "chooser_new":  { L in MainActor.assumeIsolated { Native.shared.chooserNew(L) } },
            "chooser_set_choices": { L in MainActor.assumeIsolated { Native.shared.chooserSetChoices(L) } },
            "chooser_set_placeholder": { L in MainActor.assumeIsolated { Native.shared.chooserSetPlaceholder(L) } },
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
            "download_file": { L in MainActor.assumeIsolated { Native.shared.downloadFile(L) } },
            "set_wallpaper": { L in MainActor.assumeIsolated { Native.shared.setWallpaper(L) } },
            "cache_dir":     { L in MainActor.assumeIsolated { Native.shared.cacheDir(L) } },
            "ask_choice_dismiss": { L in MainActor.assumeIsolated { Native.shared.askChoiceDismiss(L) } },
            // windows / apps (AXUIElement -- needs the Accessibility permission)
            "list_windows": { L in MainActor.assumeIsolated { Native.shared.listWindows(L) } },
            "focus_window": { L in MainActor.assumeIsolated { Native.shared.focusWindow(L) } },
            "ax_trusted":   { L in MainActor.assumeIsolated { Native.shared.axTrusted(L) } },
            "ax_prompt":    { L in MainActor.assumeIsolated { Native.shared.axPrompt(L) } },
            "focused_window_frame": { L in MainActor.assumeIsolated { Native.shared.focusedWindowFrame(L) } },
            "focused_window_title": { L in MainActor.assumeIsolated { Native.shared.focusedWindowTitle(L) } },
            "set_focused_window_frame": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFrame(L) } },
            "set_focused_window_fullscreen": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFullscreen(L) } },
            "screen_frames": { L in MainActor.assumeIsolated { Native.shared.screenFrames(L) } },
            "mouse_position": { L in MainActor.assumeIsolated { Native.shared.mousePosition(L) } },
            "set_mouse_position": { L in MainActor.assumeIsolated { Native.shared.setMousePosition(L) } },
            "app_icon":     { L in MainActor.assumeIsolated { Native.shared.appIcon(L) } },
            // platform: discover feature modules on disk
            "discover_features": { L in MainActor.assumeIsolated { Native.shared.discoverFeatures(L) } },
            // platform: the user's enabled macOS system shortcuts (read-only)
            "system_hotkeys": { L in MainActor.assumeIsolated { Native.shared.systemHotkeys(L) } },
            // app focus tracking (NSWorkspace -- no permission required)
            "frontmost_app":    { L in MainActor.assumeIsolated { Native.shared.frontmostApp(L) } },
            "on_app_activated": { L in MainActor.assumeIsolated { Native.shared.onAppActivated(L) } },
            // data files (feature-owned storage under Application Support)
            "data_dir":         { L in MainActor.assumeIsolated { Native.shared.dataDir(L) } },
            "mkdir":            { L in MainActor.assumeIsolated { Native.shared.mkdir(L) } },
            "remove_data_path": { L in MainActor.assumeIsolated { Native.shared.removeDataPath(L) } },
            // input synthesis (CGEvent posting -- needs Accessibility)
            "key_stroke":   { L in MainActor.assumeIsolated { Native.shared.keyStroke(L) } },
            "type_text":    { L in MainActor.assumeIsolated { Native.shared.typeText(L) } },
            // apps / urls
            "open_url":     { L in MainActor.assumeIsolated { Native.shared.openUrl(L) } },
            "activate_app": { L in MainActor.assumeIsolated { Native.shared.activateApp(L) } },
            "focus_browser_tab": { L in MainActor.assumeIsolated { Native.shared.focusBrowserTab(L) } },
            "app_running":       { L in MainActor.assumeIsolated { Native.shared.appRunning(L) } },
            "browser_list_tabs": { L in MainActor.assumeIsolated { Native.shared.browserListTabs(L) } },
            "browser_focus_tab_at": { L in MainActor.assumeIsolated { Native.shared.browserFocusTabAt(L) } },
            "browser_active_url":   { L in MainActor.assumeIsolated { Native.shared.browserActiveUrl(L) } },
            "extract_favicons":     { L in MainActor.assumeIsolated { Native.shared.extractFavicons(L) } },
            // input / system
            "idle_seconds": { L in MainActor.assumeIsolated { Native.shared.idleSeconds(L) } },
            "random_int": { L in MainActor.assumeIsolated { Native.shared.randomInt(L) } },
            "is_modifier_held": { L in MainActor.assumeIsolated { Native.shared.isModifierHeld(L) } },
            "system_sleep": { L in MainActor.assumeIsolated { Native.shared.systemSleep(L) } },
            "lock_screen":  { L in MainActor.assumeIsolated { Native.shared.lockScreen(L) } },
            "display_sleep": { L in MainActor.assumeIsolated { Native.shared.displaySleep(L) } },
            "start_screensaver": { L in MainActor.assumeIsolated { Native.shared.startScreensaver(L) } },
        ])
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

    private func appendLogLine(_ msg: String) {
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

    private func log(_ L: OpaquePointer?) -> Int32 {
        let msg = LuaState.string(L, 1) ?? "(nil)"
        print("[hammerdeck]", msg)
        appendLogLine(msg)
        return 0
    }

    private func stop(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let cancel = cancellers[id] {
            cancel()
            freeResource(id)
        }
        return 0
    }

    // MARK: - Triggers

    private func bindHotkey(_ L: OpaquePointer?) -> Int32 {
        let mods = LuaState.stringArray(L, 1)
        guard let key = LuaState.string(L, 2) else {
            return luaError(L, "bind_hotkey: key must be a string")
        }
        let ref = lua.makeRef(at: 3)
        // Optional 4th arg: a key-release callback (for hold / auto-repeat).
        let hasRelease = lua_type(L, 4) == LUA_TFUNCTION
        let releaseRef = hasRelease ? lua.makeRef(at: 4) : 0
        let onRelease: (() -> Void)? = hasRelease
            ? { Native.shared.lua.callRef(releaseRef) } : nil
        guard let unbind = HotkeyCenter.shared.bind(mods: mods, key: key, handler: {
            Native.shared.lua.callRef(ref)
        }, onRelease: onRelease) else {
            lua.releaseRef(ref)
            if hasRelease { lua.releaseRef(releaseRef) }
            return luaError(L, "bind_hotkey: could not register '\(mods.joined(separator: "+"))+\(key)'")
        }
        let id = registerResource {
            unbind()
            Native.shared.lua.releaseRef(ref)
            if hasRelease { Native.shared.lua.releaseRef(releaseRef) }
        }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // bind_chord(mods, key, follows, fn): prefix hotkey (mods+key) + an ordered
    // follow-key sequence. Permission-free -- see ChordCenter.
    private func bindChord(_ L: OpaquePointer?) -> Int32 {
        let mods = LuaState.stringArray(L, 1)
        guard let key = LuaState.string(L, 2) else {
            return luaError(L, "bind_chord: key must be a string")
        }
        let follows = LuaState.stringArray(L, 3)
        let ref = lua.makeRef(at: 4)
        guard let chordId = ChordCenter.shared.bind(mods: mods, key: key, follows: follows,
                                                    handler: { Native.shared.lua.callRef(ref) }) else {
            lua.releaseRef(ref)
            return luaError(L, "bind_chord: could not register chord "
                + "'\(mods.joined(separator: "+"))+\(key) -> \(follows.joined(separator: " "))'")
        }
        let id = registerResource { ChordCenter.shared.unbind(chordId); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func timerEvery(_ L: OpaquePointer?) -> Int32 {
        guard let n = LuaState.double(L, 1) else { return luaError(L, "timer_every: seconds required") }
        let ref = lua.makeRef(at: 2)
        let timer = Timer(timeInterval: n, repeats: true) { _ in
            MainActor.assumeIsolated { Native.shared.lua.callRef(ref) }
        }
        RunLoop.main.add(timer, forMode: .common)
        let id = registerResource { timer.invalidate(); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func timerAfter(_ L: OpaquePointer?) -> Int32 {
        guard let n = LuaState.double(L, 1) else { return luaError(L, "timer_after: seconds required") }
        let ref = lua.makeRef(at: 2)
        let id = allocId()
        let timer = Timer(timeInterval: n, repeats: false) { _ in
            MainActor.assumeIsolated {
                // Free BEFORE invoking so a stop(id) inside the callback is a no-op.
                Native.shared.freeResource(id)
                Native.shared.lua.callRef(ref)
                Native.shared.lua.releaseRef(ref)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cancellers[id] = { timer.invalidate(); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func timerDailyAt(_ L: OpaquePointer?) -> Int32 {
        guard let hhmm = LuaState.string(L, 1) else { return luaError(L, "timer_daily_at: 'HH:MM' required") }
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return luaError(L, "timer_daily_at: bad time '\(hhmm)'") }
        var comps = DateComponents()
        comps.hour = parts[0]
        comps.minute = parts[1]
        guard let fire = Calendar.current.nextDate(after: Date(), matching: comps,
                                                   matchingPolicy: .nextTime) else {
            return luaError(L, "timer_daily_at: cannot schedule '\(hhmm)'")
        }
        let ref = lua.makeRef(at: 2)
        let timer = Timer(fire: fire, interval: 86400, repeats: true) { _ in
            MainActor.assumeIsolated { Native.shared.lua.callRef(ref) }
        }
        RunLoop.main.add(timer, forMode: .common)
        let id = registerResource { timer.invalidate(); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func onSystemEvent(_ L: OpaquePointer?) -> Int32 {
        guard let event = LuaState.string(L, 1) else { return luaError(L, "on_system_event: event required") }
        let ref = lua.makeRef(at: 2)
        let fire = { Native.shared.lua.callRef(ref) }

        let cancel: () -> Void
        switch event {
        case "sleep", "wake":
            let name = event == "sleep" ? NSWorkspace.willSleepNotification
                                        : NSWorkspace.didWakeNotification
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { fire() }
            }
            cancel = { center.removeObserver(token); Native.shared.lua.releaseRef(ref) }
        case "screenLock", "screenUnlock":
            let name = Notification.Name(event == "screenLock" ? "com.apple.screenIsLocked"
                                                               : "com.apple.screenIsUnlocked")
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { fire() }
            }
            cancel = { center.removeObserver(token); Native.shared.lua.releaseRef(ref) }
        case "screenChanged":
            // Display added/removed/rearranged (and resolution changes). Lets a
            // feature react to a monitor being plugged in -- e.g. re-assert the
            // wallpaper on the new screen instantly instead of on the next poll.
            let center = NotificationCenter.default
            let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { fire() }
            }
            cancel = { center.removeObserver(token); Native.shared.lua.releaseRef(ref) }
        default:
            lua.releaseRef(ref)
            return luaError(L, "on_system_event: unknown event '\(event)'")
        }
        let id = registerResource(cancel)
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // MARK: - Persistence (UserDefaults)

    private func getSetting(_ L: OpaquePointer?) -> Int32 {
        guard let key = LuaState.string(L, 1) else { return luaError(L, "get_setting: key required") }
        let v = UserDefaults.standard.object(forKey: key)
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                lua_pushboolean(L, n.boolValue ? 1 : 0)
            } else {
                lua_pushnumber(L, n.doubleValue)
            }
        case let s as String:
            lua_pushstring(L, s)
        default:
            lua_pushnil(L)
        }
        return 1
    }

    private func setSetting(_ L: OpaquePointer?) -> Int32 {
        guard let key = LuaState.string(L, 1) else { return luaError(L, "set_setting: key required") }
        let defaults = UserDefaults.standard
        switch lua_type(L, 2) {
        case LUA_TBOOLEAN: defaults.set(LuaState.bool(L, 2), forKey: key)
        case LUA_TNUMBER:  defaults.set(LuaState.double(L, 2)!, forKey: key)
        case LUA_TSTRING:  defaults.set(LuaState.string(L, 2)!, forKey: key)
        case LUA_TNIL:     defaults.removeObject(forKey: key)
        default:
            return luaError(L, "set_setting: only bool/number/string/nil supported (key '\(key)')")
        }
        return 0
    }

    // MARK: - Clipboard

    private func pasteboardRead(_ L: OpaquePointer?) -> Int32 {
        if let s = NSPasteboard.general.string(forType: .string) {
            lua_pushstring(L, s)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    private func pasteboardWrite(_ L: OpaquePointer?) -> Int32 {
        guard let s = LuaState.string(L, 1) else { return luaError(L, "pasteboard_write: string required") }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        return 0
    }

    // The pasteboard types clipboard managers must not record -- password
    // managers mark secrets Concealed; expansion utilities mark ephemera
    // Transient (the nspasteboard.org convention, donor ClipboardTool's list).
    private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]

    // pasteboard_info() -> { change = <changeCount>, concealed = bool }.
    // Lets a history poller detect changes WITHOUT reading the contents, and
    // skip entries the source marked as secrets.
    private func pasteboardInfo(_ L: OpaquePointer?) -> Int32 {
        let pb = NSPasteboard.general
        let concealed = pb.types?.contains { Native.concealedTypes.contains($0.rawValue) } ?? false
        lua_createtable(L, 0, 2)
        lua_pushinteger(L, lua_Integer(pb.changeCount)); lua_setfield(L, -2, "change")
        lua_pushboolean(L, concealed ? 1 : 0);           lua_setfield(L, -2, "concealed")
        return 1
    }

    // MARK: - Output

    private func notify(_ L: OpaquePointer?) -> Int32 {
        Toast.show(title: LuaState.string(L, 1), text: LuaState.string(L, 2) ?? "",
                   centered: false, seconds: 5)
        return 0
    }

    private func alert(_ L: OpaquePointer?) -> Int32 {
        Toast.show(title: nil, text: LuaState.string(L, 1) ?? "",
                   centered: true, seconds: 2)
        return 0
    }

    // MARK: - Banner

    private func bannerShow(_ L: OpaquePointer?) -> Int32 {
        let banner = BannerPanel(text: LuaState.string(L, 1) ?? "")
        let id = registerResource { banner.close() }
        banners[id] = banner
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func bannerSetText(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let text = LuaState.string(L, 2) {
            banners[id]?.setText(text)
        }
        return 0
    }

    // MARK: - Chooser

    private func chooserNew(_ L: OpaquePointer?) -> Int32 {
        let searchSubText = LuaState.bool(L, 1)
        let selectRef = lua.makeRef(at: 2)
        let hideRef = lua.makeRef(at: 3)
        let panel = ChooserPanel(
            searchSubText: searchSubText,
            onSelect: { idx in
                Native.shared.lua.callRef(selectRef) { L in
                    if let idx { lua_pushinteger(L, lua_Integer(idx)) } else { lua_pushnil(L) }
                    return 1
                }
            },
            onHide: { Native.shared.lua.callRef(hideRef) }
        )
        let id = registerResource {
            panel.close()
            Native.shared.lua.releaseRef(selectRef)
            Native.shared.lua.releaseRef(hideRef)
        }
        choosers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func chooser(_ L: OpaquePointer?) -> ChooserPanel? {
        guard let id = LuaState.int(L, 1).map(Int32.init) else { return nil }
        return choosers[id]
    }

    private func chooserSetChoices(_ L: OpaquePointer?) -> Int32 {
        guard let panel = chooser(L) else { return 0 }
        let entries = LuaState.dictArray(L, 2).map { d in
            ChooserEntry(text: d["text"] as? String ?? "",
                         subText: d["subText"] as? String,
                         iconToken: d["image"] as? String,
                         valid: (d["valid"] as? Bool) ?? true,
                         shortcut: d["shortcut"] as? String)
        }
        panel.setChoices(entries)
        return 0
    }

    private func chooserSetPlaceholder(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.setPlaceholder(LuaState.string(L, 2) ?? "")
        return 0
    }

    private func chooserSetQuery(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.setQuery(LuaState.string(L, 2))
        return 0
    }

    private func chooserShow(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.show()
        return 0
    }

    private func chooserHide(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.hide()
        return 0
    }

    private func chooserVisible(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, (chooser(L)?.isVisible ?? false) ? 1 : 0)
        return 1
    }

    private func chooserSelectedRow(_ L: OpaquePointer?) -> Int32 {
        lua_pushinteger(L, lua_Integer(chooser(L)?.selectedRow() ?? 0))
        return 1
    }

    private func chooserSetSelectedRow(_ L: OpaquePointer?) -> Int32 {
        if let n = LuaState.int(L, 2) { chooser(L)?.setSelectedRow(n) }
        return 0
    }

    private func chooserSelect(_ L: OpaquePointer?) -> Int32 {
        if let n = LuaState.int(L, 2) { chooser(L)?.select(n) }
        return 0
    }

    // MARK: - UI introspection (TEST-ONLY)
    //
    // A read-only window into the live native panels, for `swift test`. This is
    // deliberately NOT surfaced through the adapter / ctx: a feature must never
    // be able to enumerate or drive another feature's panels (same
    // least-privilege reasoning as the `commands` capability gate). Tests reach
    // it via `@testable import HammerdeckKit`; the headless Lua suite uses the
    // fake adapter's own chooser introspection instead. Keeping it here means
    // the "real panel" assertions an agent/CI needs live in one obvious place.

    /// A snapshot of one live chooser panel's state. `id` is stable across a
    /// feature's repeat invocations (a feature reuses its chooser), so a test
    /// can follow a single chooser through opens/closes.
    struct ChooserSnapshot {
        let id: Int32
        let visible: Bool
        let isKey: Bool
        let placeholder: String
        let rowCount: Int
        let selectedRow: Int
        let entries: [String]
    }

    /// Every live chooser's state, id-sorted.
    func chooserSnapshots() -> [ChooserSnapshot] {
        choosers.map { id, p in
            ChooserSnapshot(id: id, visible: p.isVisible, isKey: p.isKey,
                            placeholder: p.placeholder, rowCount: p.visibleRowCount,
                            selectedRow: p.selectedRow(), entries: p.visibleEntryTexts)
        }.sorted { $0.id < $1.id }
    }

    /// Just the visible choosers (the common assertion target).
    func visibleChoosers() -> [ChooserSnapshot] {
        chooserSnapshots().filter(\.visible)
    }

    /// Drive a chooser's selection as the user would (fires its onSelect), by
    /// the id a snapshot reported -- so a test can pick a row without
    /// synthesizing a keystroke or a click. `row` is 1-based into the visible list.
    func selectChooserRow(id: Int32, row: Int) {
        choosers[id]?.select(row)
    }

    // MARK: - askChoice (one-shot dialog built on ChooserPanel)

    private func askChoice(_ L: OpaquePointer?) -> Int32 {
        let title = LuaState.string(L, 1) ?? ""
        let infos = LuaState.stringArray(L, 2)
        let actions = LuaState.stringArray(L, 3)
        let ref = lua.makeRef(at: 4)

        let id = allocId()
        var done = false
        let panel = ChooserPanel(
            searchSubText: false,
            onSelect: { idx in
                guard !done else { return }
                done = true
                let actionIdx = (idx != nil && idx! <= actions.count) ? idx : nil
                Native.shared.lua.callRef(ref) { L in
                    if let a = actionIdx { lua_pushinteger(L, lua_Integer(a)) } else { lua_pushnil(L) }
                    return 1
                }
                Native.shared.lua.releaseRef(ref)
                Native.shared.freeResource(id)
            },
            onHide: {}
        )
        var entries = actions.map { ChooserEntry(text: $0, subText: nil, iconToken: nil, valid: true) }
        entries += infos.map { ChooserEntry(text: $0, subText: nil, iconToken: nil, valid: false) }
        panel.setChoices(entries)
        panel.setPlaceholder(title)
        panel.show()

        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            panel.close()
        }
        choosers[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func askChoiceDismiss(_ L: OpaquePointer?) -> Int32 {
        chooser(L)?.select(0)   // out-of-range select = finish(nil) = cancelled
        return 0
    }

    // MARK: - askText (one-shot text prompt)

    private func askText(_ L: OpaquePointer?) -> Int32 {
        let title = LuaState.string(L, 1) ?? ""
        let placeholder = LuaState.string(L, 2) ?? ""
        let defaultValue = LuaState.string(L, 3) ?? ""
        let ref = lua.makeRef(at: 4)

        let id = allocId()
        var done = false
        let panel = AskTextPanel(title: title, placeholder: placeholder,
                                 defaultValue: defaultValue) { text in
            guard !done else { return }
            done = true
            Native.shared.lua.callRef(ref) { L in
                if let text { lua_pushstring(L, text) } else { lua_pushnil(L) }
                return 1
            }
            Native.shared.lua.releaseRef(ref)
            Native.shared.freeResource(id)
        }
        cancellers[id] = {
            if !done {
                done = true
                Native.shared.lua.releaseRef(ref)
            }
            panel.close()
        }
        askTexts[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func askTextDismiss(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init) { askTexts[id]?.dismiss() }
        return 0
    }

    // MARK: - Progress strip

    private func progressShow(_ L: OpaquePointer?) -> Int32 {
        let panel = ProgressPanel()
        let id = registerResource { panel.close() }
        progresses[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func progressSet(_ L: OpaquePointer?) -> Int32 {
        if let id = LuaState.int(L, 1).map(Int32.init), let f = LuaState.double(L, 2) {
            progresses[id]?.setProgress(f)
        }
        return 0
    }

    // MARK: - Usage widget (desktop-pinned stats card)

    private func usageWidgetShow(_ L: OpaquePointer?) -> Int32 {
        let panel = UsageWidgetPanel(screenIndex: LuaState.int(L, 1) ?? 1)
        let id = registerResource { panel.close() }
        widgets[id] = panel
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    private func usageWidgetSet(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1).map(Int32.init),
              let dict = LuaState.any(L, 2) as? [String: Any],
              let data = UsageWidgetData(dict) else { return 0 }
        widgets[id]?.setData(data)
        return 0
    }

    // MARK: - Network / files / wallpaper

    // Async GET; callback gets (status, body|nil). Body is decoded as UTF-8
    // text (this surface is for JSON/HTML APIs -- binary payloads go through
    // download_file, which never round-trips bytes into a Lua string).
    private func httpGet(_ L: OpaquePointer?) -> Int32 {
        guard let url = LuaState.string(L, 1), let u = URL(string: url) else {
            return luaError(L, "http_get: url required")
        }
        let headers = (LuaState.any(L, 2) as? [String: Any]) ?? [:]
        let ref = lua.makeRef(at: 3)
        var req = URLRequest(url: u)
        for (k, v) in headers {
            if let s = v as? String { req.setValue(s, forHTTPHeaderField: k) }
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_pushinteger(L, lua_Integer(status))
                        if let body { lua_pushstring(L, body) } else { lua_pushnil(L) }
                        return 2
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }.resume()
        return 0
    }

    private func downloadFile(_ L: OpaquePointer?) -> Int32 {
        guard let url = LuaState.string(L, 1), let u = URL(string: url),
              let path = LuaState.string(L, 2) else {
            return luaError(L, "download_file: url and path required")
        }
        let ref = lua.makeRef(at: 3)
        URLSession.shared.downloadTask(with: u) { tmp, resp, _ in
            var ok = false
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp, (200..<300).contains(status) {
                let fm = FileManager.default
                try? fm.removeItem(atPath: path)
                ok = (try? fm.moveItem(at: tmp, to: URL(fileURLWithPath: path))) != nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_pushboolean(L, ok ? 1 : 0)
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }.resume()
        return 0
    }

    private func setWallpaper(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1) else {
            return luaError(L, "set_wallpaper: path required")
        }
        // mode "primary" => only the main display; anything else (incl. nil)
        // => every screen. Default is all -- a multi-display setup otherwise
        // leaves the other monitors on their old wallpaper.
        let mode = LuaState.string(L, 2)
        let url = URL(fileURLWithPath: path)
        let ws = NSWorkspace.shared
        let targets = (mode == "primary")
            ? (NSScreen.main.map { [$0] } ?? [])
            : NSScreen.screens
        var ok = !targets.isEmpty
        for screen in targets {
            if (try? ws.setDesktopImageURL(url, for: screen)) == nil { ok = false }
        }
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    private func cacheDir(_ L: OpaquePointer?) -> Int32 {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hammerdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lua_pushstring(L, dir.path)
        return 1
    }

    // MARK: - Mouse locator (fire-and-forget, like alert)

    private func locateMouse(_ L: OpaquePointer?) -> Int32 {
        let seconds = LuaState.double(L, 1) ?? 3
        mouseLocator?.close()                       // re-invoke replaces the live one
        mouseLocator = MouseLocatorPanel(seconds: seconds) {
            Native.shared.mouseLocator = nil
        }
        return 0
    }

    // MARK: - Windows / apps (AXUIElement)

    // list_windows() -> Lua window handles, MRU-first. The Lua side never sees
    // an AXUIElement: each call rebuilds `axWindowCache` (id -> element) and
    // focus_window(id) resolves from it -- window_switcher always lists right
    // before focusing, so a one-listing cache is exactly the right lifetime.
    private var axWindowCache: [Int: AXUIElement] = [:]
    private var nextWindowId = 1

    /// Real window enumeration: AXUIElement per app for titles + elements
    /// (Accessibility permission only -- no Screen Recording, which CGWindowList
    /// window NAMES would require), z-ordered via CGWindowList bounds matching
    /// (front-to-back ~= focus recency, the same ordering hs.window.orderedWindows
    /// gives the donor). Returns {} when the permission is missing -- features
    /// check ax_trusted/ax_prompt to onboard.
    private func listWindows(_ L: OpaquePointer?) -> Int32 {
        axWindowCache.removeAll()
        guard AXIsProcessTrusted() else {
            lua_createtable(L, 0, 0)
            return 1
        }

        // Z-ordered (front to back) on-screen normal-layer windows.
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]]) ?? []
        struct CGRow { let pid: pid_t; let bounds: CGRect; let z: Int }
        var cgRows: [CGRow] = []
        for w in cgList {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let bDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: bDict as CFDictionary)
            else { continue }
            cgRows.append(CGRow(pid: pid_t(pid), bounds: bounds, z: cgRows.count))
        }

        struct Row {
            let z: Int; let id: Int; let app: String; let title: String
            let bundleID: String; let screenName: String?
        }
        var rows: [Row] = []
        // Screen names only matter (and only render) on multi-display setups.
        let screens = NSScreen.screens
        let namedScreens: [(rect: CGRect, name: String)] = screens.count > 1
            ? screens.map { (axRect($0.frame), $0.localizedName) } : []
        var seenPids = Set<pid_t>()
        for pid in cgRows.map(\.pid) where !seenPids.contains(pid) {
            seenPids.insert(pid)
            guard let runApp = NSRunningApplication(processIdentifier: pid) else { continue }
            let appName = runApp.localizedName ?? "?"
            let bundleID = runApp.bundleIdentifier ?? ""

            var winsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                kAXWindowsAttribute as CFString,
                                                &winsRef) == .success,
                  let axWins = winsRef as? [AXUIElement] else { continue }
            for win in axWins {
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleRef)
                guard (subroleRef as? String) == kAXStandardWindowSubrole as String else { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // Match this AX window to its CG z-position by frame (both are
                // top-left-origin screen coordinates; small tolerance for the
                // odd subpixel disagreement).
                var pos = CGPoint.zero, size = CGSize.zero
                var posRef: CFTypeRef?, sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                   let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
                    AXValueGetValue((pv as! AXValue), .cgPoint, &pos)
                }
                if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
                    AXValueGetValue((sv as! AXValue), .cgSize, &size)
                }
                let z = cgRows.first { r in
                    r.pid == pid
                        && abs(r.bounds.minX - pos.x) < 2 && abs(r.bounds.minY - pos.y) < 2
                        && abs(r.bounds.width - size.width) < 2
                        && abs(r.bounds.height - size.height) < 2
                }?.z ?? Int.max   // unmatched (e.g. minimized): list last

                let frame = CGRect(origin: pos, size: size)
                let screenName = namedScreens.first {
                    $0.rect.contains(CGPoint(x: frame.midX, y: frame.midY))
                }?.name

                let id = nextWindowId
                nextWindowId += 1
                axWindowCache[id] = win
                rows.append(Row(z: z, id: id, app: appName,
                                title: title.isEmpty ? appName : title,
                                bundleID: bundleID, screenName: screenName))
            }
        }
        rows.sort { $0.z < $1.z }

        lua_createtable(L, Int32(rows.count), 0)
        for (i, r) in rows.enumerated() {
            lua_createtable(L, 0, 5)
            lua_pushinteger(L, lua_Integer(r.id)); lua_setfield(L, -2, "id")
            lua_pushstring(L, r.title);            lua_setfield(L, -2, "title")
            lua_pushstring(L, r.app);              lua_setfield(L, -2, "appName")
            lua_pushstring(L, r.bundleID);         lua_setfield(L, -2, "bundleID")
            if let s = r.screenName {
                lua_pushstring(L, s);              lua_setfield(L, -2, "screenName")
            }
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    private func axTrusted(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, AXIsProcessTrusted() ? 1 : 0)
        return 1
    }

    // MARK: - Focused-window frame surface (window_snap)
    //
    // ONE coordinate system crosses the seam: top-left-origin global points
    // (what AX speaks). NSScreen frames are bottom-left-origin, so they are
    // converted here -- the Lua side never sees a flipped y.

    private func axRect(_ r: NSRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
    }

    private func focusedAXWindow() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(app.processIdentifier),
                kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private func axWindowFrame(_ win: AXUIElement) -> CGRect {
        var pos = CGPoint.zero, size = CGSize.zero
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
           let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue((pv as! AXValue), .cgPoint, &pos)
        }
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue((sv as! AXValue), .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private func pushRect(_ L: OpaquePointer?, _ r: CGRect) {
        lua_createtable(L, 0, 4)
        lua_pushnumber(L, r.minX);   lua_setfield(L, -2, "x")
        lua_pushnumber(L, r.minY);   lua_setfield(L, -2, "y")
        lua_pushnumber(L, r.width);  lua_setfield(L, -2, "w")
        lua_pushnumber(L, r.height); lua_setfield(L, -2, "h")
    }

    // focused_window_frame() -> nil | { x,y,w,h, fullscreen, screenIndex,
    // screen = {x,y,w,h} } -- screen is the window's screen's VISIBLE frame
    // (menubar/dock excluded, hs screen:frame() parity).
    private func focusedWindowFrame(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushnil(L)
            return 1
        }
        let frame = axWindowFrame(win)

        var fullscreen = false
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef) == .success {
            fullscreen = (fsRef as? Bool) ?? false
        }

        // The window's screen: the one containing its midpoint, else the first.
        let screens = NSScreen.screens
        let mid = CGPoint(x: frame.midX, y: frame.midY)
        var screenIndex = 0
        for (i, s) in screens.enumerated() where axRect(s.frame).contains(mid) {
            screenIndex = i
            break
        }
        let visible = axRect(screens.isEmpty ? NSRect(x: 0, y: 0, width: 1440, height: 900)
                                             : screens[screenIndex].visibleFrame)

        pushRect(L, frame)
        lua_pushboolean(L, fullscreen ? 1 : 0); lua_setfield(L, -2, "fullscreen")
        lua_pushinteger(L, lua_Integer(screenIndex + 1)); lua_setfield(L, -2, "screenIndex")
        pushRect(L, visible); lua_setfield(L, -2, "screen")
        return 1
    }

    // focused_window_title() -> string|nil (needs Accessibility; nil without).
    // Cheap single-attribute read -- usage_stats derives the editor project
    // name from it.
    private func focusedWindowTitle(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushnil(L)
            return 1
        }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        if let title = titleRef as? String, !title.isEmpty {
            lua_pushstring(L, title)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // set_focused_window_frame(x, y, w, h) -> bool
    private func setFocusedWindowFrame(_ L: OpaquePointer?) -> Int32 {
        guard let x = LuaState.double(L, 1), let y = LuaState.double(L, 2),
              let w = LuaState.double(L, 3), let h = LuaState.double(L, 4),
              let win = focusedAXWindow() else {
            lua_pushboolean(L, 0)
            return 1
        }
        var pos = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        var ok = false
        if let pv = AXValueCreate(.cgPoint, &pos), let sv = AXValueCreate(.cgSize, &size) {
            // Size first, then position, then size again: apps clamp a frame
            // against their current screen, so a cross-screen move applied as
            // position-then-size (or size-then-position alone) can leave the
            // size clamped to the OLD screen. The hs.window dance.
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
            ok = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) == .success
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        }
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // set_focused_window_fullscreen(bool) -> bool
    private func setFocusedWindowFullscreen(_ L: OpaquePointer?) -> Int32 {
        guard let win = focusedAXWindow() else {
            lua_pushboolean(L, 0)
            return 1
        }
        let on = LuaState.bool(L, 1)
        let ok = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString,
                                              (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        lua_pushboolean(L, ok == .success ? 1 : 0)
        return 1
    }

    // screen_frames() -> array of visible frames (top-left-origin), the order
    // NSScreen.screens gives (primary first).
    private func screenFrames(_ L: OpaquePointer?) -> Int32 {
        let screens = NSScreen.screens
        lua_createtable(L, Int32(screens.count), 0)
        for (i, s) in screens.enumerated() {
            pushRect(L, axRect(s.visibleFrame))
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    // mouse_position() -> {x, y} (top-left-origin, same space as frames).
    private func mousePosition(_ L: OpaquePointer?) -> Int32 {
        let p = CGEvent(source: nil)?.location ?? .zero
        lua_createtable(L, 0, 2)
        lua_pushnumber(L, p.x); lua_setfield(L, -2, "x")
        lua_pushnumber(L, p.y); lua_setfield(L, -2, "y")
        return 1
    }

    private func setMousePosition(_ L: OpaquePointer?) -> Int32 {
        guard let x = LuaState.double(L, 1), let y = LuaState.double(L, 2) else {
            return luaError(L, "set_mouse_position: x and y required")
        }
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        return 0
    }

    // Shows the system "wants to control this computer" prompt when untrusted
    // (the Accessibility onboarding hook for features that need windows).
    private func axPrompt(_ L: OpaquePointer?) -> Int32 {
        // The literal key (== kAXTrustedCheckOptionPrompt, stable API contract);
        // the constant itself is a global var Swift 6 flags as concurrency-unsafe.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        lua_pushboolean(L, AXIsProcessTrustedWithOptions(opts) ? 1 : 0)
        return 1
    }

    // Returns the bare names of feature modules in `dir`: a "<name>/init.lua"
    // subdirectory or a flat "<name>.lua" file each yields "<name>". The
    // registry prefixes "features." and loads them. Drives autodiscovery +
    // hot-plug (reload re-scans).
    private func discoverFeatures(_ L: OpaquePointer?) -> Int32 {
        guard let dir = LuaState.string(L, 1) else { return luaError(L, "discover_features: dir required") }
        let fm = FileManager.default
        var names = Set<String>()
        if let entries = try? fm.contentsOfDirectory(atPath: dir) {
            for entry in entries where !entry.hasPrefix(".") {
                let full = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue {
                    if fm.fileExists(atPath: (full as NSString).appendingPathComponent("init.lua")) {
                        names.insert(entry)
                    }
                } else if entry.hasSuffix(".lua"), entry != "init.lua" {
                    names.insert(String(entry.dropLast(4)))
                }
            }
        }
        lua_createtable(L, Int32(names.count), 0)
        for (i, name) in names.sorted().enumerated() {
            lua_pushstring(L, name)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    // MARK: - System shortcuts (read-only)

    // system_hotkeys(): the user's currently-enabled macOS system shortcuts,
    // returned as hotkey-shaped specs { mods = {...}, key = "...", name = "..." }
    // so the config UI can warn before a binding collides with Spotlight,
    // input-source switching, Mission Control, etc. macOS owns these
    // (com.apple.symbolichotkeys) -- we only READ them, never rebind.
    private func systemHotkeys(_ L: OpaquePointer?) -> Int32 {
        let entries = Native.readSymbolicHotkeys()
        lua_createtable(L, Int32(entries.count), 0)
        for (i, e) in entries.enumerated() {
            lua_createtable(L, 0, 3)
            lua_createtable(L, Int32(e.mods.count), 0)
            for (j, m) in e.mods.enumerated() {
                lua_pushstring(L, m)
                lua_rawseti(L, -2, lua_Integer(j + 1))
            }
            lua_setfield(L, -2, "mods")
            lua_pushstring(L, e.key);  lua_setfield(L, -2, "key")
            lua_pushstring(L, e.name); lua_setfield(L, -2, "name")
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    /// Parse ~/Library/Preferences/com.apple.symbolichotkeys.plist into the
    /// enabled shortcuts we can represent (mods + a key our keyCodes map knows).
    /// Each plist entry is { enabled, value = { parameters = (char, keyCode,
    /// modifierMask) } }; modifierMask uses the Cocoa NSEvent flag bits.
    static func readSymbolicHotkeys() -> [(mods: [String], key: String, name: String)] {
        guard let raw = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                  "com.apple.symbolichotkeys" as CFString)
                as? [String: Any] else { return [] }
        var out: [(mods: [String], key: String, name: String)] = []
        for (idStr, v) in raw {
            guard let entry = v as? [String: Any] else { continue }
            let enabled: Bool = (entry["enabled"] as? Bool)
                ?? ((entry["enabled"] as? NSNumber)?.intValue != 0 ? true : false)
            guard enabled,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let keyCode = (params[1] as? NSNumber)?.intValue,
                  let mask = (params[2] as? NSNumber)?.intValue,
                  let keyName = Native.codeToKeyName[keyCode]
            else { continue }
            var mods: [String] = []
            if mask & 0x100000 != 0 { mods.append("cmd") }
            if mask & 0x080000 != 0 { mods.append("alt") }
            if mask & 0x040000 != 0 { mods.append("ctrl") }
            if mask & 0x020000 != 0 { mods.append("shift") }
            let name = Native.symbolicHotkeyNames[Int(idStr) ?? -1] ?? "a macOS system shortcut"
            out.append((mods: mods, key: keyName, name: name))
        }
        return out
    }

    /// Reverse of HotkeyCenter.keyCodes (positional code -> a key name our
    /// trigger specs use). Canonical spellings win over their aliases so the
    /// emitted key string matches what the editor stores (e.g. "return", not
    /// "enter") for the conflict comparison.
    static let codeToKeyName: [Int: String] = {
        let preferred: Set<String> = ["return", "delete", "escape", "space", "tab",
                                      "left", "right", "up", "down"]
        var map: [Int: String] = [:]
        for (name, code) in HotkeyCenter.keyCodes {
            if let cur = map[code] {
                if preferred.contains(name) && !preferred.contains(cur) { map[code] = name }
            } else {
                map[code] = name
            }
        }
        return map
    }()

    /// Friendly names for the well-known symbolic-hotkey ids, for the warning
    /// text. Detection works without these (id absent -> generic wording); they
    /// only make the message specific ("Spotlight" vs "a macOS system shortcut").
    static let symbolicHotkeyNames: [Int: String] = [
        32: "Mission Control",
        33: "Application Windows",
        36: "Show Desktop",
        28: "Save screenshot to file",
        29: "Copy screenshot to clipboard",
        30: "Save screenshot of area to file",
        31: "Copy screenshot of area to clipboard",
        60: "Select previous input source",
        61: "Select next input source",
        64: "Spotlight",
        65: "Spotlight (Finder window)",
        79: "Move to space on the left",
        81: "Move to space on the right",
        118: "Switch to Desktop 1",
        160: "Launchpad",
        162: "Quick Note",
        175: "Notification Center",
        184: "Screenshot and recording options",
    ]

    // focus_window(id): raise the window and activate its app. The id must
    // come from the most recent list_windows() call.
    private func focusWindow(_ L: OpaquePointer?) -> Int32 {
        guard let id = LuaState.int(L, 1), let win = axWindowCache[id] else {
            lua_pushboolean(L, 0)
            return 1
        }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        var pid: pid_t = 0
        if AXUIElementGetPid(win, &pid) == .success {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        lua_pushboolean(L, 1)
        return 1
    }

    // MARK: - App focus tracking

    private func frontmostApp(_ L: OpaquePointer?) -> Int32 {
        if let name = NSWorkspace.shared.frontmostApplication?.localizedName {
            lua_pushstring(L, name)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // on_app_activated(fn): fn(appName) fires whenever an application becomes
    // frontmost. NSWorkspace notification -- no Accessibility needed.
    private func onAppActivated(_ L: OpaquePointer?) -> Int32 {
        let ref = lua.makeRef(at: 1)
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                       object: nil, queue: .main) { note in
            let name = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication)?.localizedName
            MainActor.assumeIsolated {
                Native.shared.lua.callRef(ref) { L in
                    if let name { lua_pushstring(L, name) } else { lua_pushnil(L) }
                    return 1
                }
            }
        }
        let id = registerResource { center.removeObserver(token); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // MARK: - Data files (Application Support)

    // App-owned durable data directory (distinct from cache_dir: the OS may
    // purge caches; usage logs and other feature data must survive).
    private func dataDir(_ L: OpaquePointer?) -> Int32 {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Hammerdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lua_pushstring(L, dir.path)
        return 1
    }

    private func mkdir(_ L: OpaquePointer?) -> Int32 {
        guard let path = LuaState.string(L, 1) else { return luaError(L, "mkdir: path required") }
        let ok = (try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)) != nil
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    // remove_data_path(relpath) -> bool. CURATED delete: only paths UNDER the
    // app's data dir, relative, no traversal -- the retention sweep's tool,
    // never a general rm.
    private func removeDataPath(_ L: OpaquePointer?) -> Int32 {
        guard let rel = LuaState.string(L, 1),
              !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("..") else {
            return luaError(L, "remove_data_path: a relative path under the data dir is required")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first?
            .appendingPathComponent("Hammerdeck", isDirectory: true)
        guard let target = base?.appendingPathComponent(rel) else {
            lua_pushboolean(L, 0)
            return 1
        }
        let ok = (try? FileManager.default.removeItem(at: target)) != nil
        lua_pushboolean(L, ok ? 1 : 0)
        return 1
    }

    private func appIcon(_ L: OpaquePointer?) -> Int32 {
        if let bundleID = LuaState.string(L, 1) {
            lua_pushstring(L, "appicon:" + bundleID)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // extract_favicons(outDir, domains, cb): pull REAL site icons from
    // Chrome's local Favicons sqlite DB (the donor's extract_favicons.py,
    // ported to Swift -- no python). The DB is copied first (Chrome holds a
    // lock), the largest PNG per domain wins, PNG magic verified. Works
    // offline and covers <link rel> icons the sites never serve at
    // /favicon.ico. cb(savedDomains[]). Existing files are not overwritten.
    private func extractFavicons(_ L: OpaquePointer?) -> Int32 {
        guard let outDir = LuaState.string(L, 1) else {
            return luaError(L, "extract_favicons: outDir required")
        }
        let domains = LuaState.stringArray(L, 2)
        let ref = lua.makeRef(at: 3)
        DispatchQueue.global(qos: .utility).async {
            let saved = Self.extractFaviconsSync(outDir: outDir, domains: domains)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        lua_createtable(L, Int32(saved.count), 0)
                        for (i, d) in saved.enumerated() {
                            lua_pushstring(L, d)
                            lua_rawseti(L, -2, lua_Integer(i + 1))
                        }
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }
        return 0
    }

    /// The donor's extract_favicons.py, in-process: copy the DB (Chrome holds
    /// a lock), largest PNG per domain, magic verified. Pure helper, any queue.
    private nonisolated static func extractFaviconsSync(outDir: String,
                                                        domains: [String]) -> [String] {
        let fm = FileManager.default
        let dbPath = NSHomeDirectory()
            + "/Library/Application Support/Google/Chrome/Default/Favicons"
        guard fm.fileExists(atPath: dbPath) else { return [] }
        // UUID, not pid: two overlapping extractions in this process must not
        // share (and defer-delete) each other's DB copy.
        let tmp = NSTemporaryDirectory() + "hammerdeck-favicons-\(UUID().uuidString).db"
        defer { try? fm.removeItem(atPath: tmp) }
        do { try fm.copyItem(atPath: dbPath, toPath: tmp) } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        // The host must END at the domain (next char "/" / ":" / end-of-url),
        // so "github.com" never matches a lookalike like github.com.evil.io.
        let sql = """
        SELECT fb.image_data FROM icon_mapping im
        JOIN favicons f ON im.icon_id = f.id
        JOIN favicon_bitmaps fb ON f.id = fb.icon_id
        WHERE im.page_url LIKE ? OR im.page_url LIKE ? OR im.page_url LIKE ?
        ORDER BY fb.width * fb.height DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var saved: [String] = []
        for domain in domains {
            let out = outDir + "/" + domain + ".png"
            guard !fm.fileExists(atPath: out) else { continue }
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, "%://\(domain)/%", -1, transient)
            sqlite3_bind_text(stmt, 2, "%://\(domain):%", -1, transient)
            sqlite3_bind_text(stmt, 3, "%://\(domain)", -1, transient)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(stmt, 0) {
                let n = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: n)
                if n > 8, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
                   (try? data.write(to: URL(fileURLWithPath: out))) != nil {
                    saved.append(domain)
                }
            }
        }
        return saved
    }

    // MARK: - Input synthesis (CGEvent posting -- the system delivers these to
    // the frontmost app; macOS requires the Accessibility permission)

    private static func carbonFlags(_ mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "alt", "option":   flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift":           flags.insert(.maskShift)
            default: break
            }
        }
        return flags
    }

    // key_stroke(mods, key): one modified key press (e.g. cmd+c) to the
    // frontmost app. Key names are HotkeyCenter's (US-positional).
    private func keyStroke(_ L: OpaquePointer?) -> Int32 {
        let mods = LuaState.stringArray(L, 1)
        guard let key = LuaState.string(L, 2),
              let code = HotkeyCenter.keyCodes[key.lowercased()] else {
            return luaError(L, "key_stroke: unknown key '\(LuaState.string(L, 2) ?? "?")'")
        }
        let flags = Native.carbonFlags(mods)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        return 0
    }

    // type_text(text): type a unicode string into the frontmost app (no
    // layout/keycode mapping needed -- the donor's hs.eventtap.keyStrokes).
    private func typeText(_ L: OpaquePointer?) -> Int32 {
        guard let text = LuaState.string(L, 1) else {
            return luaError(L, "type_text: text required")
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        // Chunked: keyboardSetUnicodeString reliably carries ~20 UTF-16 units.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            i += 20
        }
        return 0
    }

    // MARK: - Apps / URLs

    private func openUrl(_ L: OpaquePointer?) -> Int32 {
        guard let s = LuaState.string(L, 1), let url = URL(string: s) else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, NSWorkspace.shared.open(url) ? 1 : 0)
        return 1
    }

    // activate_app(name): bring a RUNNING app (by localized name) frontmost.
    // Returns false when it is not running (donor semantics -- no launching).
    private func activateApp(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            lua_pushboolean(L, 0)
            return 1
        }
        if let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.localizedName == name }) {
            app.activate()
            lua_pushboolean(L, 1)
        } else {
            lua_pushboolean(L, 0)
        }
        return 1
    }

    // focus_browser_tab(pattern, fallbackURL) -> found. Brings the first
    // Chrome tab whose URL contains `pattern` to front; opens fallbackURL in a
    // new tab when absent (the donor miscBindings "locate otter" flow,
    // parameterized). CURATED AppleScript: the script is a fixed template in
    // the seam -- features never run arbitrary osascript. First use triggers
    // the macOS Automation permission prompt ("control Google Chrome").
    private func focusBrowserTab(_ L: OpaquePointer?) -> Int32 {
        guard let pattern = LuaState.string(L, 1), let fallback = LuaState.string(L, 2) else {
            return luaError(L, "focus_browser_tab: pattern and fallbackURL required")
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // The donor's script shape: snapshot all tab URLs first, then act by
        // indices (mutating window order while iterating live lists misbehaves).
        let script = """
        activate application "Google Chrome"
        tell application "Google Chrome" to set windowTabList to URL of tabs of every window
        set found to false
        set windowIndex to 1
        repeat with thisWindowsTabs in windowTabList
            set tabIndex to 1
            repeat with tabURL in thisWindowsTabs
                if tabURL as text contains "\(esc(pattern))" then
                    tell application "Google Chrome"
                        set index of window windowIndex to 1
                        set active tab index of window 1 to tabIndex
                    end tell
                    set found to true
                    exit repeat
                end if
                set tabIndex to tabIndex + 1
            end repeat
            if found then exit repeat
            set windowIndex to windowIndex + 1
        end repeat
        if not found then
            tell application "Google Chrome" to make new tab at window 1 with properties {URL:"\(esc(fallback))"}
        end if
        return found
        """
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errInfo)
        if let errInfo {
            // Chrome missing / Automation permission denied: degrade, log why.
            print("[hammerdeck] focus_browser_tab failed: "
                + ((errInfo[NSAppleScript.errorMessage] as? String) ?? "\(errInfo)"))
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, result?.booleanValue == true ? 1 : 0)
        return 1
    }

    // MARK: - Browser tabs (curated JXA templates -- tab_switcher)
    //
    // Only these two browsers are scriptable here; the app-name argument is
    // validated against this whitelist before it goes anywhere near a script.
    private static let scriptableBrowsers: Set<String> = ["Google Chrome", "Safari"]

    private func appRunning(_ L: OpaquePointer?) -> Int32 {
        let name = LuaState.string(L, 1)
        let running = name != nil && NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == name
        }
        lua_pushboolean(L, running ? 1 : 0)
        return 1
    }

    // Run a fixed JXA template asynchronously via osascript; cb(stdout|nil).
    // Out-of-process like the donor's hs.task -- a slow browser cannot hang
    // the host. The script TEXT is never caller-supplied.
    private func runJXA(_ script: String, _ ref: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.terminationHandler = { proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = proc.terminationStatus == 0
                ? String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Native.shared.lua.callRef(ref) { L in
                        if let text { lua_pushstring(L, text) } else { lua_pushnil(L) }
                        return 1
                    }
                    Native.shared.lua.releaseRef(ref)
                }
            }
        }
        do { try p.run() } catch {
            lua.callRef(ref) { L in lua_pushnil(L); return 1 }
            lua.releaseRef(ref)
        }
    }

    // browser_list_tabs(app, cb): cb gets a JSON string
    // {"tabs":[{title,url,winId,tabIndex,visible}...]} or nil. JSON is built
    // with JSON.stringify (the donor hand-concatenated and broke on quotes).
    private func browserListTabs(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app) else {
            return luaError(L, "browser_list_tabs: unsupported app")
        }
        let ref = lua.makeRef(at: 2)
        let script = """
        function run() {
          var app = Application("\(app)");
          var out = [];
          var wins = app.windows();
          for (var wi = 0; wi < wins.length; wi++) {
            var win = wins[wi];
            var winId = 0, visible = true, name = "";
            try { winId = win.id(); } catch (e) {}
            try { visible = win.visible(); } catch (e) {}
            try { name = win.name() || ""; } catch (e) {}
            if (!name || name.length === 0) { visible = false; }
            var tabs = [];
            try { tabs = win.tabs(); } catch (e) {}
            for (var ti = 0; ti < tabs.length; ti++) {
              var tab = tabs[ti], title = "", url = "";
              try { title = ("\(app)" === "Safari") ? tab.name() : tab.title(); } catch (e) {}
              try { url = tab.url() || ""; } catch (e) {}
              out.push({ title: title || "", url: url, winId: winId,
                         tabIndex: ti + 1, visible: visible });
            }
          }
          return JSON.stringify({ tabs: out });
        }
        """
        runJXA(script, ref)
        return 0
    }

    // browser_focus_tab_at(app, winId, tabIndex, cb): raises the window, makes
    // the tab active; cb gets {"url": "..."} JSON (the tab's CURRENT url, which
    // may have drifted since listing) or nil.
    private func browserFocusTabAt(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app),
              let winId = LuaState.int(L, 2), let tabIndex = LuaState.int(L, 3) else {
            return luaError(L, "browser_focus_tab_at: unsupported app or bad indices")
        }
        let ref = lua.makeRef(at: 4)
        let script = """
        function run() {
          var app = Application("\(app)");
          app.activate();
          var wins = app.windows();
          for (var wi = 0; wi < wins.length; wi++) {
            var win = wins[wi];
            var id = -1;
            try { id = win.id(); } catch (e) {}
            if (id === \(winId)) {
              win.index = 1;
              var tabs = win.tabs();
              if (\(tabIndex) >= 1 && \(tabIndex) <= tabs.length) {
                var tab = tabs[\(tabIndex) - 1];
                if ("\(app)" === "Safari") { win.currentTab = tab; }
                else { win.activeTabIndex = \(tabIndex); }
                var url = "";
                try { url = tab.url() || ""; } catch (e) {}
                return JSON.stringify({ url: url });
              }
            }
          }
          return JSON.stringify({});
        }
        """
        runJXA(script, ref)
        return 0
    }

    // browser_active_url(app) -> url|nil. Sync + cheap (one property read);
    // this is the curated "what is the browser looking at" call (#9 context).
    private func browserActiveUrl(_ L: OpaquePointer?) -> Int32 {
        guard let app = LuaState.string(L, 1), Native.scriptableBrowsers.contains(app) else {
            lua_pushnil(L)
            return 1
        }
        let source = app == "Safari"
            ? "tell application \"Safari\" to return URL of front document"
            : "tell application \"Google Chrome\" to return URL of active tab of front window"
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errInfo)
        if errInfo == nil, let url = result?.stringValue, !url.isEmpty {
            lua_pushstring(L, url)
        } else {
            lua_pushnil(L)
        }
        return 1
    }

    // MARK: - Input / system

    private func idleSeconds(_ L: OpaquePointer?) -> Int32 {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown,
                                    .rightMouseDown, .scrollWheel, .flagsChanged]
        let idle = types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
        lua_pushnumber(L, idle)
        return 1
    }

    // random_int(min, max): a CRYPTOGRAPHICALLY SECURE uniform integer in the
    // inclusive range [min, max]. Features (e.g. password_generator) only have
    // Lua's non-crypto math.random, so the one source of secure randomness lives
    // here at the seam. Rejection sampling drops the modulo-biased tail so every
    // value in the range is equally likely.
    private func randomInt(_ L: OpaquePointer?) -> Int32 {
        guard let lo = LuaState.int(L, 1), let hi = LuaState.int(L, 2), lo <= hi else {
            return luaError(L, "random_int: need integer min <= max")
        }
        // Work in modular (bit-pattern) space so a wide range straddling zero
        // can't trap: a plain `hi - lo` would overflow Int. `span` is the
        // inclusive count; span == 0 means the range covers the entire 64-bit
        // domain (2^64 values), where every random word maps 1:1 with no bias.
        let loBits = UInt64(bitPattern: Int64(lo))
        let span = (UInt64(bitPattern: Int64(hi)) &- loBits) &+ 1
        var r = Native.secureRandomU64()
        if span != 0 {
            let limit = UInt64.max - (UInt64.max % span)     // largest unbiased ceiling
            while r >= limit { r = Native.secureRandomU64() }
            r = r % span
        }
        lua_pushinteger(L, lua_Integer(Int64(bitPattern: loBits &+ r)))
        return 1
    }

    /// 8 secure-random bytes as a UInt64 (SecRandomCopyBytes; arc4random only as
    /// a never-expected fallback). Pure, any queue.
    private nonisolated static func secureRandomU64() -> UInt64 {
        var v: UInt64 = 0
        let rc = withUnsafeMutableBytes(of: &v) {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        if rc != errSecSuccess {
            v = (UInt64(arc4random()) << 32) | UInt64(arc4random())
        }
        return v
    }

    private func isModifierHeld(_ L: OpaquePointer?) -> Int32 {
        let flags = NSEvent.modifierFlags
        let held: Bool
        switch LuaState.string(L, 1) ?? "" {
        case "alt":   held = flags.contains(.option)
        case "cmd":   held = flags.contains(.command)
        case "ctrl":  held = flags.contains(.control)
        case "shift": held = flags.contains(.shift)
        default:      held = false
        }
        lua_pushboolean(L, held ? 1 : 0)
        return 1
    }

    private func systemSleep(_ L: OpaquePointer?) -> Int32 {
        runCommand("/usr/bin/pmset", ["sleepnow"])
        return 0
    }

    private func lockScreen(_ L: OpaquePointer?) -> Int32 {
        // Display sleep locks the session when "require password immediately"
        // is on (the default). Direct lock APIs are private; revisit in M3.
        runCommand("/usr/bin/pmset", ["displaysleepnow"])
        return 0
    }

    private func displaySleep(_ L: OpaquePointer?) -> Int32 {
        // Turn the display off (no lock intent -- distinct from lockScreen,
        // which will switch to a real lock API in M3).
        runCommand("/usr/bin/pmset", ["displaysleepnow"])
        return 0
    }

    private func startScreensaver(_ L: OpaquePointer?) -> Int32 {
        runCommand("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        return 0
    }

    private func runCommand(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    // MARK: - Errors

    private func luaError(_ L: OpaquePointer?, _ message: String) -> Int32 {
        lua_pushstring(L, message)
        return lua_error(L)
    }
}
