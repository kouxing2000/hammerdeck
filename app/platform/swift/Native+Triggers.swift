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

// Holds whichever link of a daily timer chain is currently armed, so one stable
// resource id keeps cancelling the right timer as the chain re-arms itself.
// Main-actor bound, which is what makes it Sendable: the timer's @Sendable block
// captures it to re-arm the chain, and its mutable `timer` is only ever touched
// on the main actor.
@MainActor
private final class DailyTimerBox {
    var timer: Timer?
}

extension Native {
    // MARK: - Triggers

    func bindHotkey(_ L: OpaquePointer?) -> Int32 {
        let mods = LuaState.stringArray(L, 1)
        guard let key = LuaState.string(L, 2) else {
            return luaError(L, "bind_hotkey: key must be a string")
        }
        // A silently-dropped unknown modifier would REGISTER a less-modified
        // combo (e.g. {"cmmd","alt"}+k binds plain alt+k and hijacks it), and
        // registration succeeds so no error would surface. Reject loudly --
        // including non-string entries, which stringArray filters out before
        // firstUnknown could see them (the same bug through a side door).
        if lua_type(L, 1) == LUA_TTABLE, Int(lua_rawlen(L, 1)) != mods.count {
            return luaError(L, "bind_hotkey: mods must be modifier name strings")
        }
        if let bad = KeyModifier.firstUnknown(in: mods) {
            return luaError(L, "bind_hotkey: unknown modifier '\(bad)'")
        }
        let ref = lua.makeRef(at: 3)
        // Optional 4th arg: a key-release callback (for hold / auto-repeat).
        let hasRelease = lua_type(L, 4) == LUA_TFUNCTION
        let releaseRef = hasRelease ? lua.makeRef(at: 4) : 0
        let onRelease: (() -> Void)? = hasRelease
            ? { Native.shared.lua.callRef(releaseRef) } : nil
        // Optional 5th arg: shadow. When true, SHADOW any standalone hotkey on
        // this combo for the binding's lifetime -- park the incumbent before
        // registering, hand it back on stop. Lets a transient bare-key layer
        // (a modal's cell keys) accept the leader's modifiers still held (the
        // Hyper-leader "sticky key" motion) without the global on that combo
        // stealing it. Two live registrations of one combo dispatch ambiguously,
        // so the incumbent MUST be cleared first (mirrors ChordCenter's sticky
        // follows). No-op when nothing is registered on the combo.
        let restore: (() -> Void)? = (LuaState.bool(L, 5) ?? false)
            ? HotkeyCenter.shared.park(key: key, mods: mods) : nil
        guard let unbind = HotkeyCenter.shared.bind(mods: mods, key: key, handler: {
            Native.shared.lua.callRef(ref)
        }, onRelease: onRelease) else {
            restore?()
            lua.releaseRef(ref)
            if hasRelease { lua.releaseRef(releaseRef) }
            return luaError(L, "bind_hotkey: could not register '\(mods.joined(separator: "+"))+\(key)'")
        }
        let id = registerResource {
            unbind()
            restore?()
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
        // Same guards as bind_hotkey: a dropped modifier (unknown string OR a
        // non-string entry stringArray filtered) arms the chord on a
        // less-modified prefix. Reject loudly.
        if lua_type(L, 1) == LUA_TTABLE, Int(lua_rawlen(L, 1)) != mods.count {
            return luaError(L, "bind_chord: mods must be modifier name strings")
        }
        if let bad = KeyModifier.firstUnknown(in: mods) {
            return luaError(L, "bind_chord: unknown modifier '\(bad)'")
        }
        let follows = LuaState.stringArray(L, 3)
        // Optional 5th/6th args: the action label + its SF Symbol name, both
        // shown in the which-key hint. Read before makeRef just to keep the
        // positional reads in argument order.
        let label = LuaState.string(L, 5) ?? ""
        let icon = LuaState.string(L, 6)
        let ref = lua.makeRef(at: 4)
        guard let chordId = ChordCenter.shared.bind(mods: mods, key: key, follows: follows,
                                                    label: label, icon: icon,
                                                    handler: { Native.shared.lua.callRef(ref) }) else {
            lua.releaseRef(ref)
            return luaError(L, "bind_chord: could not register chord "
                + "'\(mods.joined(separator: "+"))+\(key) -> \(follows.joined(separator: " "))'")
        }
        let id = registerResource { ChordCenter.shared.unbind(chordId); Native.shared.lua.releaseRef(ref) }
        lua_pushinteger(L, lua_Integer(id))
        return 1
    }

    // NOTE -- why repeating ticks are NOT suppressed during a blocking seam call.
    // A synchronous seam call (AppleScript) spins a NESTED event loop, so timers
    // keep firing inside it and re-enter Lua mid-operation; that nesting is how
    // the 2026-07-23 freeze compounded. Skipping such ticks was tried and
    // REVERTED: it silently loses events, because a repeating timer here is not
    // always a resumable "poll".
    //   * count_down does `elapsed = elapsed + 1` per tick (tick-counting, not a
    //     ctx.now() delta), so every dropped tick makes the countdown finish a
    //     second late -- measurably, since a browser poll blocks often enough.
    //   * sleep_schedule's Phase 3 only fires inside a ~20s window on a 10s
    //     timer, so losing those ticks loses the day's scheduled sleep.
    // The root fix is bounding the waits themselves (Native+AppleScript's
    // `with timeout`, and the measured AX ceiling in Native+Windows), which caps
    // the nesting instead of dropping the caller's work. Re-entrancy during a
    // now-bounded wait is the long-standing status quo, not the bug that hung us.
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

    /// The next wall-clock occurrence of `hour:minute` strictly after `date`.
    ///
    /// Named and static so the DST behaviour is testable without waiting a day:
    /// iterate it and every result must land on the requested clock time.
    static func nextDailyFire(after date: Date, hour: Int, minute: Int,
                              calendar: Calendar = .current) -> Date? {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return calendar.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }

    /// Arm one link of a daily chain, re-arming from inside the fire.
    ///
    /// A one-shot chain rather than a repeating Timer because a repeating timer
    /// can only add a FIXED interval, and a calendar day is 23 or 25 hours across
    /// a DST transition. A 86400s repeat therefore slips an hour at the boundary
    /// and stays an hour off for the life of the process -- "sleep at 00:30"
    /// silently becomes 01:30 until the next relaunch. Re-asking the calendar
    /// each time is what keeps the wall-clock promise the API makes.
    private func armDaily(hour: Int, minute: Int, ref: Int32, box: DailyTimerBox) {
        // A nil here ends the chain FOREVER -- the user's daily automation simply
        // stops, with the feature still reporting itself bound. `timerDailyAt`
        // rejects any time this could refuse, so it should be unreachable, which
        // is exactly why it must speak: an unreachable branch that silently
        // disables an automation is unfalsifiable from the log otherwise.
        guard let fire = Native.nextDailyFire(after: Date(), hour: hour, minute: minute) else {
            seamLog(String(format: "timer_daily_at: no next fire for %02d:%02d -- chain ended",
                           hour, minute))
            return
        }
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak box] _ in
            MainActor.assumeIsolated {
                guard let box else { return }
                // Re-arm BEFORE the callback, so a stop(id) made from inside the
                // Lua handler cancels the link that is now live, and a raising
                // handler cannot silently end the chain.
                Native.shared.armDaily(hour: hour, minute: minute, ref: ref, box: box)
                Native.shared.lua.callRef(ref)
            }
        }
        box.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func timerDailyAt(_ L: OpaquePointer?) -> Int32 {
        guard let hhmm = LuaState.string(L, 1) else { return luaError(L, "timer_daily_at: 'HH:MM' required") }
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return luaError(L, "timer_daily_at: bad time '\(hhmm)'") }
        guard Native.nextDailyFire(after: Date(), hour: parts[0], minute: parts[1]) != nil else {
            return luaError(L, "timer_daily_at: cannot schedule '\(hhmm)'")
        }
        let ref = lua.makeRef(at: 2)
        let box = DailyTimerBox()
        armDaily(hour: parts[0], minute: parts[1], ref: ref, box: box)
        let id = registerResource {
            box.timer?.invalidate()
            box.timer = nil
            Native.shared.lua.releaseRef(ref)
        }
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
