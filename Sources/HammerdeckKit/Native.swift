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
            "set_focused_window_frame": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFrame(L) } },
            "set_focused_window_fullscreen": { L in MainActor.assumeIsolated { Native.shared.setFocusedWindowFullscreen(L) } },
            "screen_frames": { L in MainActor.assumeIsolated { Native.shared.screenFrames(L) } },
            "mouse_position": { L in MainActor.assumeIsolated { Native.shared.mousePosition(L) } },
            "set_mouse_position": { L in MainActor.assumeIsolated { Native.shared.setMousePosition(L) } },
            "app_icon":     { L in MainActor.assumeIsolated { Native.shared.appIcon(L) } },
            // platform: discover feature modules on disk
            "discover_features": { L in MainActor.assumeIsolated { Native.shared.discoverFeatures(L) } },
            // app focus tracking (NSWorkspace -- no permission required)
            "frontmost_app":    { L in MainActor.assumeIsolated { Native.shared.frontmostApp(L) } },
            "on_app_activated": { L in MainActor.assumeIsolated { Native.shared.onAppActivated(L) } },
            // data files (feature-owned storage under Application Support)
            "data_dir":         { L in MainActor.assumeIsolated { Native.shared.dataDir(L) } },
            "mkdir":            { L in MainActor.assumeIsolated { Native.shared.mkdir(L) } },
            // input synthesis (CGEvent posting -- needs Accessibility)
            "key_stroke":   { L in MainActor.assumeIsolated { Native.shared.keyStroke(L) } },
            "type_text":    { L in MainActor.assumeIsolated { Native.shared.typeText(L) } },
            // apps / urls
            "open_url":     { L in MainActor.assumeIsolated { Native.shared.openUrl(L) } },
            "activate_app": { L in MainActor.assumeIsolated { Native.shared.activateApp(L) } },
            "focus_browser_tab": { L in MainActor.assumeIsolated { Native.shared.focusBrowserTab(L) } },
            // input / system
            "idle_seconds": { L in MainActor.assumeIsolated { Native.shared.idleSeconds(L) } },
            "is_modifier_held": { L in MainActor.assumeIsolated { Native.shared.isModifierHeld(L) } },
            "system_sleep": { L in MainActor.assumeIsolated { Native.shared.systemSleep(L) } },
            "lock_screen":  { L in MainActor.assumeIsolated { Native.shared.lockScreen(L) } },
            "display_sleep": { L in MainActor.assumeIsolated { Native.shared.displaySleep(L) } },
            "start_screensaver": { L in MainActor.assumeIsolated { Native.shared.startScreensaver(L) } },
        ])
    }

    // MARK: - Core

    private func log(_ L: OpaquePointer?) -> Int32 {
        print("[hammerdeck]", LuaState.string(L, 1) ?? "(nil)")
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
        guard let unbind = HotkeyCenter.shared.bind(mods: mods, key: key, handler: {
            Native.shared.lua.callRef(ref)
        }) else {
            lua.releaseRef(ref)
            return luaError(L, "bind_hotkey: could not register '\(mods.joined(separator: "+"))+\(key)'")
        }
        let id = registerResource { unbind(); Native.shared.lua.releaseRef(ref) }
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
                         valid: (d["valid"] as? Bool) ?? true)
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
        let panel = UsageWidgetPanel()
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
        var ok = false
        if let screen = NSScreen.main {
            ok = (try? NSWorkspace.shared.setDesktopImageURL(
                URL(fileURLWithPath: path), for: screen)) != nil
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
    // focus_window(id) resolves from it -- window_jump always lists right
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

        struct Row { let z: Int; let id: Int; let app: String; let title: String; let bundleID: String }
        var rows: [Row] = []
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

                let id = nextWindowId
                nextWindowId += 1
                axWindowCache[id] = win
                rows.append(Row(z: z, id: id, app: appName,
                                title: title.isEmpty ? appName : title, bundleID: bundleID))
            }
        }
        rows.sort { $0.z < $1.z }

        lua_createtable(L, Int32(rows.count), 0)
        for (i, r) in rows.enumerated() {
            lua_createtable(L, 0, 4)
            lua_pushinteger(L, lua_Integer(r.id)); lua_setfield(L, -2, "id")
            lua_pushstring(L, r.title);            lua_setfield(L, -2, "title")
            lua_pushstring(L, r.app);              lua_setfield(L, -2, "appName")
            lua_pushstring(L, r.bundleID);         lua_setfield(L, -2, "bundleID")
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    private func axTrusted(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, AXIsProcessTrusted() ? 1 : 0)
        return 1
    }

    // MARK: - Focused-window frame surface (window_arrange)
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

    private func appIcon(_ L: OpaquePointer?) -> Int32 {
        if let bundleID = LuaState.string(L, 1) {
            lua_pushstring(L, "appicon:" + bundleID)
        } else {
            lua_pushnil(L)
        }
        return 1
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
