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
    }

    // MARK: - Table registration

    func installBindings() {
        lua.registerTable("native", [
            // core
            "log":          { L in MainActor.assumeIsolated { Native.shared.log(L) } },
            "stop":         { L in MainActor.assumeIsolated { Native.shared.stop(L) } },
            // triggers
            "bind_hotkey":  { L in MainActor.assumeIsolated { Native.shared.bindHotkey(L) } },
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
            "ask_choice_dismiss": { L in MainActor.assumeIsolated { Native.shared.askChoiceDismiss(L) } },
            // windows / apps (list/focus are M2 Slice 2 -- AXUIElement)
            "list_windows": { L in MainActor.assumeIsolated { Native.shared.listWindows(L) } },
            "focus_window": { L in MainActor.assumeIsolated { Native.shared.focusWindow(L) } },
            "app_icon":     { L in MainActor.assumeIsolated { Native.shared.appIcon(L) } },
            // platform: discover feature modules on disk
            "discover_features": { L in MainActor.assumeIsolated { Native.shared.discoverFeatures(L) } },
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

    // MARK: - Windows / apps

    // M2 Slice 2: real window enumeration needs AXUIElement + the Accessibility
    // permission. Stubbed so window_jump degrades gracefully until then.
    private func listWindows(_ L: OpaquePointer?) -> Int32 {
        lua_createtable(L, 0, 0)
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

    private func focusWindow(_ L: OpaquePointer?) -> Int32 {
        lua_pushboolean(L, 0)
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
