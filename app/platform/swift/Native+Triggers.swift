// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Triggers: hotkeys, chords, timers, system events.

import AppKit
import CLua

extension Native {
    // MARK: - Triggers

    func bindHotkey(_ L: OpaquePointer?) -> Int32 {
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
    func bindChord(_ L: OpaquePointer?) -> Int32 {
        let mods = LuaState.stringArray(L, 1)
        guard let key = LuaState.string(L, 2) else {
            return luaError(L, "bind_chord: key must be a string")
        }
        let follows = LuaState.stringArray(L, 3)
        // Optional 5th arg: the action label, shown in the which-key hint. Read
        // before makeRef just to keep the positional reads in argument order.
        let label = LuaState.string(L, 5) ?? ""
        let ref = lua.makeRef(at: 4)
        guard let chordId = ChordCenter.shared.bind(mods: mods, key: key, follows: follows,
                                                    label: label,
                                                    handler: { Native.shared.lua.callRef(ref) }) else {
            lua.releaseRef(ref)
            return luaError(L, "bind_chord: could not register chord "
                + "'\(mods.joined(separator: "+"))+\(key) -> \(follows.joined(separator: " "))'")
        }
        let id = registerResource { ChordCenter.shared.unbind(chordId); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    func timerEvery(_ L: OpaquePointer?) -> Int32 {
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

    func timerAfter(_ L: OpaquePointer?) -> Int32 {
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

    func timerDailyAt(_ L: OpaquePointer?) -> Int32 {
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

    func onSystemEvent(_ L: OpaquePointer?) -> Int32 {
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
}
