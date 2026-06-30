// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Triggers: hotkeys, chords, timers, system events.

import AppKit
import CLua
import IOKit.ps

// Boxes a fire callback so IOPSNotificationCreateRunLoopSource's @convention(c)
// callback (which can't capture) can reach it through the opaque context pointer.
private final class PowerNotifyBox {
    let fire: () -> Void
    init(_ fire: @escaping () -> Void) { self.fire = fire }
}

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
        let cancel: () -> Void
        switch event {
        case "sleep", "wake":
            let name = event == "sleep" ? NSWorkspace.willSleepNotification
                                        : NSWorkspace.didWakeNotification
            cancel = Native.bindObserver(NSWorkspace.shared.notificationCenter, [name], ref)
        case "screenLock", "screenUnlock":
            let name = Notification.Name(event == "screenLock" ? "com.apple.screenIsLocked"
                                                               : "com.apple.screenIsUnlocked")
            cancel = Native.bindObserver(DistributedNotificationCenter.default(), [name], ref)
        case "screenChanged":
            // Display added/removed/rearranged (and resolution changes). Lets a
            // feature react to a monitor being plugged in -- e.g. re-assert the
            // wallpaper on the new screen instantly instead of on the next poll.
            cancel = Native.bindObserver(NotificationCenter.default,
                                         [NSApplication.didChangeScreenParametersNotification], ref)
        case "appearanceChanged":
            // Dark/light mode flip. The re-read trigger behind the `appearance` signal.
            cancel = Native.bindObserver(DistributedNotificationCenter.default(),
                                         [Notification.Name("AppleInterfaceThemeChangedNotification")], ref)
        case "appsChanged":
            // An app launched or quit -- the re-read trigger behind `runningApps`.
            cancel = Native.bindObserver(NSWorkspace.shared.notificationCenter,
                                         [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification], ref)
        case "powerChanged":
            // AC <-> battery (and battery-level) change, via IOKit's power-source
            // run-loop source. The re-read trigger behind `powerSource`.
            let box = PowerNotifyBox { MainActor.assumeIsolated { Native.shared.lua.callRef(ref) } }
            let ctx = Unmanaged.passRetained(box).toOpaque()
            guard let src = IOPSNotificationCreateRunLoopSource({ raw in
                guard let raw else { return }
                Unmanaged<PowerNotifyBox>.fromOpaque(raw).takeUnretainedValue().fire()
            }, ctx)?.takeRetainedValue() else {
                Unmanaged<PowerNotifyBox>.fromOpaque(ctx).release()
                lua.releaseRef(ref)
                return luaError(L, "on_system_event: could not observe the power source")
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            cancel = {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                Unmanaged<PowerNotifyBox>.fromOpaque(ctx).release()
                Native.shared.lua.releaseRef(ref)
            }
        default:
            lua.releaseRef(ref)
            return luaError(L, "on_system_event: unknown event '\(event)'")
        }
        let id = registerResource(cancel)
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }
}
