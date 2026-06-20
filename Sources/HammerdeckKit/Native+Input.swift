// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Input synthesis (CGEvent) + system primitives: idle, secure random, modifiers, sleep/lock/display.

import AppKit
import CLua
import Security

extension Native {
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
    func keyStroke(_ L: OpaquePointer?) -> Int32 {
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
    func typeText(_ L: OpaquePointer?) -> Int32 {
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

    // MARK: - Input / system

    func idleSeconds(_ L: OpaquePointer?) -> Int32 {
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
    func randomInt(_ L: OpaquePointer?) -> Int32 {
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

    func isModifierHeld(_ L: OpaquePointer?) -> Int32 {
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

    func systemSleep(_ L: OpaquePointer?) -> Int32 {
        runCommand("/usr/bin/pmset", ["sleepnow"])
        return 0
    }

    func lockScreen(_ L: OpaquePointer?) -> Int32 {
        // Display sleep locks the session when "require password immediately"
        // is on (the default). Direct lock APIs are private; revisit in M3.
        runCommand("/usr/bin/pmset", ["displaysleepnow"])
        return 0
    }

    func displaySleep(_ L: OpaquePointer?) -> Int32 {
        // Turn the display off (no lock intent -- distinct from lockScreen,
        // which will switch to a real lock API in M3).
        runCommand("/usr/bin/pmset", ["displaysleepnow"])
        return 0
    }

    func startScreensaver(_ L: OpaquePointer?) -> Int32 {
        runCommand("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        return 0
    }

    private func runCommand(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}
