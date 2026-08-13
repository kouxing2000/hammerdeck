// Native.swift split: this file is one domain slice of the `Native`
// seam (see Native.swift for the class, shared state, and installBindings).
// Input synthesis (CGEvent) + system primitives: idle, secure random, modifiers, sleep/lock/display.

import AppKit
import CLua
import Security

/// Thread-safe accumulator for a child process's stderr.
///
/// `Process` delivers reads on one queue and termination on another, both through
/// @Sendable closures, so the buffer cannot be a captured `var`. A small locked
/// box is the honest shape: @unchecked because the compiler cannot see the lock.
private final class StderrSink: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func drain() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

extension Native {
    // MARK: - Input synthesis (CGEvent posting -- the system delivers these to
    // the frontmost app; macOS requires the Accessibility permission)

    /// Log backstop for callers that reach synthesis WITHOUT a `ctx`.
    ///
    /// `CGEvent.post` is a VOID call that fails silently without Accessibility --
    /// no return value, no error, no exception -- so an untrusted build looks
    /// exactly like a working one.
    ///
    /// The user-facing onboarding (prompt + an alert naming the feature) lives in
    /// `ctx.lua`, because only that layer knows which feature asked and can show
    /// UI. This is deliberately NOT that gate, and for `key_stroke`/`type_text` it
    /// is currently unreachable: `ctx` refuses those before the seam is called.
    /// It earns its place on the third path -- `effects.lua` calls
    /// `adapter.mediaKey` DIRECTLY for the media-key rule effect, and a rules
    /// engine has no `ctx` to alert through, so without this a rule would fire,
    /// report success, and do nothing with nothing written down.
    ///
    /// Throttled: a held-down hotkey would otherwise write a line per repeat.
    ///
    /// Note the grant is keyed to the CODE SIGNATURE, so a Developer-ID-signed
    /// .app and a dev build are separate entries in System Settings, and granting
    /// one does nothing for the other.
    private func inputTrusted(_ what: String) -> Bool {
        if AXIsProcessTrusted() { return true }
        seamLogThrottled("input:untrusted",
                         "\(what): Accessibility not granted -- synthesized input is silently "
                         + "discarded by the system. Grant it in System Settings > Privacy & "
                         + "Security > Accessibility for THIS build (the grant is per code signature).")
        return false
    }

    private static func carbonFlags(_ mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for m in mods {
            if let mod = KeyModifier.parse(m) { flags.insert(mod.cgFlag) }
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
        // A dropped modifier would post the LESS-modified combo -- e.g. a bare
        // "v" typed into the user's document instead of cmd+v. Reject loudly,
        // including non-string entries stringArray filtered before the read.
        if lua_type(L, 1) == LUA_TTABLE, Int(lua_rawlen(L, 1)) != mods.count {
            return luaError(L, "key_stroke: mods must be modifier name strings")
        }
        if let bad = KeyModifier.firstUnknown(in: mods) {
            return luaError(L, "key_stroke: unknown modifier '\(bad)'")
        }
        guard inputTrusted("key_stroke") else { return 0 }
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
        guard inputTrusted("type_text") else { return 0 }
        let src = CGEventSource(stateID: .combinedSessionState)
        // Chunked: keyboardSetUnicodeString reliably carries ~20 UTF-16 units.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                // Clear the modifiers, ALWAYS. `.combinedSessionState` makes a posted
                // event inherit whatever is physically held right now -- and this runs
                // from a hotkey the user is still holding. insert_datetime's default is
                // Hyper (cmd+alt+ctrl+D), so every character went out as
                // cmd+alt+ctrl+<char>: the receiving app reads that as a SHORTCUT, not
                // text, and types nothing while everything reports success.
                //
                // keyStroke above never had this bug because it assigns `flags`
                // explicitly; only this path left them inherited.
                //
                // No fake-adapter test can see this -- the defect lives in the
                // interaction with real hardware modifier state, which the fake has no
                // notion of. It is caught by pressing the key on a real machine.
                e?.flags = []
                e?.post(tap: .cghidEventTap)
            }
            i += 20
        }
        return 0
    }

    // media_key(name): post a media/transport key as a system-defined NSEvent --
    // whatever app is playing (Music, Spotify, a browser) picks it up, no app
    // targeting. `name`: "playpause" | "next" | "previous" (NX_KEYTYPE_PLAY 16 /
    // _NEXT 17 / _PREVIOUS 18). Like key_stroke this posts to the HID tap, so it
    // needs the Accessibility grant. The down/up state is carried in BOTH the
    // modifier flags and data1's low half (0xA00 down / 0xB00 up) -- the encoding
    // the aux-control handler expects (subtype 8 = NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    func mediaKey(_ L: OpaquePointer?) -> Int32 {
        let codes: [String: Int] = ["playpause": 16, "next": 17, "previous": 18]
        guard let name = LuaState.string(L, 1), let key = codes[name] else {
            return luaError(L, "media_key: unknown key '\(LuaState.string(L, 1) ?? "?")'")
        }
        guard inputTrusted("media_key") else { return 0 }
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (key << 16) | state, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
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

    // valid_modifiers(): the modifier tokens the seam accepts (sorted), so
    // the Lua layer (triggers.validate) reads the SAME whitelist KeyModifier
    // enforces -- one authority, no hand-synced copies.
    func validModifiers(_ L: OpaquePointer?) -> Int32 {
        let tokens = KeyModifier.validTokens
        lua_createtable(L, Int32(tokens.count), 0)
        for (i, t) in tokens.enumerated() {
            lua_pushstring(L, t)
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }
        return 1
    }

    func isModifierHeld(_ L: OpaquePointer?) -> Int32 {
        // An unknown token used to read as "never held", silently killing
        // hold-to-keep-open behavior (cyclingChooser). Reject loudly instead.
        guard let name = LuaState.string(L, 1), let mod = KeyModifier.parse(name) else {
            return luaError(L, "is_modifier_held: unknown modifier '\(LuaState.string(L, 1) ?? "?")'")
        }
        lua_pushboolean(L, NSEvent.modifierFlags.contains(mod.nsFlag) ? 1 : 0)
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

    // say(text): speak a line aloud through the system speech synthesizer
    // (fire-and-forget). Lets a rule announce an event by voice -- "Battery low",
    // "Standup in five" -- when a banner the user has to look at won't do.
    func speak(_ L: OpaquePointer?) -> Int32 {
        guard let text = LuaState.string(L, 1) else {
            return luaError(L, "say: text required")
        }
        // `--` ends option parsing so text that starts with a dash ("-5C outside")
        // is spoken, not silently swallowed as a `say` flag (which would log a lying
        // green "fired" while saying nothing).
        runCommand("/usr/bin/say", ["--", text])
        return 0
    }

    // run_shortcut(name): fire a macOS Shortcut by name (fire-and-forget). The
    // generic automation escape hatch -- a user Shortcut can toggle Focus/DND, set
    // volume, run HomeKit scenes, and anything else Shortcuts can do, so a rule
    // reaches all of that without a per-action native atom.
    func runShortcut(_ L: OpaquePointer?) -> Int32 {
        guard let name = LuaState.string(L, 1) else {
            return luaError(L, "run_shortcut: name required")
        }
        runCommand("/usr/bin/shortcuts", ["run", name])
        return 0
    }

    /// Launch a helper tool and REPORT what happened to the daily log.
    ///
    /// Six seam calls ride on this -- sleep, lock, display sleep, screensaver,
    /// speak, and run_shortcut. It used to be `try? p.run()` and nothing else,
    /// which swallowed three distinct failures at once: a launch error (the `try?`),
    /// a non-zero exit (never waited for), and whatever the tool said on stderr
    /// (never read). `run_shortcut` is the one that bites -- it backs the "Run
    /// Shortcut" rule effect, so renaming the shortcut made the rule fire, report
    /// success, and do nothing. Same shape as the type_text bug.
    ///
    /// Stays ASYNCHRONOUS. Waiting here would block the main thread on another
    /// process, which is the freeze this seam already has rules about; the
    /// termination handler reports instead. It is `@Sendable`, so the log call
    /// hops to the main actor rather than calling seamLog directly -- and it goes
    /// to seamLog, not NSLog, because the daily log is the file a user can
    /// actually send us.
    private func runCommand(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        let label = ([path] + args).joined(separator: " ")

        // Drain stderr on a BACKGROUND read, unconditionally -- never inside the
        // `terminationStatus != 0` branch. A pipe holds ~64KB; a chatty but
        // SUCCESSFUL helper that exceeds it blocks forever on write, so it never
        // exits, the termination handler never fires, and the process hangs with
        // nothing logged. That is the exact failure class this reporting exists to
        // remove, so it must not be the thing that introduces one.
        // A reference box, not a captured `var`: the reader handler and the
        // termination handler are both @Sendable and run on different threads, so
        // Swift 6 rejects a shared mutable capture outright. The lock is what makes
        // the @unchecked honest.
        let sink = StderrSink()
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { fh.readabilityHandler = nil; return }
            sink.append(chunk)
        }

        p.terminationHandler = { proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let data = sink.drain()
            guard proc.terminationStatus != 0 else { return }
            let stderr = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                // Throttle on the FULL command, not just the tool path: keying on
                // path alone would report one failing `shortcuts run <name>` and
                // swallow every other shortcut's failure for a minute -- and
                // run_shortcut is the case this was written for.
                Native.shared.seamLogThrottled(
                    "cmd:" + label,
                    "\(label): exited \(proc.terminationStatus)"
                        + (stderr.isEmpty ? "" : " -- \(stderr.prefix(200))"))
            }
        }
        do {
            try p.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            seamLogThrottled("cmd:" + label, "\(label): could not launch -- \(error.localizedDescription)")
        }
    }
}
