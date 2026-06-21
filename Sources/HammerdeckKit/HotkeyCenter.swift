import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey.
///
/// Chosen over a CGEvent tap because it needs NO Accessibility permission and
/// is the same mechanism Hammerspoon's hs.hotkey uses underneath. Deprecated
/// but stable for decades; revisit only if Apple ever ships a replacement.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var carbonSpecs: [UInt32: (keyCode: UInt32, mods: UInt32)] = [:]  // for re-register on resume
    private var suspendedIds: Set<UInt32> = []   // ids parked while suspended
    private var suspendDepth = 0
    private var nextId: UInt32 = 1
    private var installed = false

    private init() {}

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        // Subscribe to BOTH press and release. Carbon does not auto-repeat a
        // registered hotkey -- one press, one release, however long it's held;
        // callers that want hold/repeat behaviour build it from the release
        // edge (modal.lua auto-repeat, hold_to_quit).
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            // Carbon dispatches on the main thread.
            MainActor.assumeIsolated {
                if released {
                    HotkeyCenter.shared.releaseHandlers[hkID.id]?()
                } else {
                    HotkeyCenter.shared.handlers[hkID.id]?()
                }
            }
            return noErr
        }, 2, &specs, nil, nil)
    }

    /// Returns an unregister closure, or nil if the key is unknown. `onRelease`,
    /// if given, fires on the key-up edge of the same combo.
    func bind(mods: [String], key: String, handler: @escaping () -> Void,
              onRelease: (() -> Void)? = nil) -> (() -> Void)? {
        guard let keyCode = HotkeyCenter.keyCodes[key.lowercased()] else { return nil }
        installHandlerIfNeeded()

        var carbonMods: UInt32 = 0
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command": carbonMods |= UInt32(cmdKey)
            case "alt", "option":  carbonMods |= UInt32(optionKey)
            case "ctrl", "control": carbonMods |= UInt32(controlKey)
            case "shift":          carbonMods |= UInt32(shiftKey)
            default: break
            }
        }

        let id = nextId
        nextId += 1
        // While suspended (a recorder is capturing), park the binding without a
        // live Carbon ref so it can't fire mid-capture; resume() registers it.
        if suspendDepth == 0 {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x48_44_4B_59) /* 'HDKY' */, id: id)
            let status = RegisterEventHotKey(UInt32(keyCode), carbonMods, hkID,
                                             GetEventDispatcherTarget(), 0, &ref)
            guard status == noErr, let hotkeyRef = ref else { return nil }
            refs[id] = hotkeyRef
        } else {
            suspendedIds.insert(id)
        }

        handlers[id] = handler
        if let onRelease { releaseHandlers[id] = onRelease }
        carbonSpecs[id] = (UInt32(keyCode), carbonMods)
        return { [weak self] in
            guard let self else { return }
            if let r = self.refs[id] { UnregisterEventHotKey(r) }
            self.refs[id] = nil
            self.suspendedIds.remove(id)
            self.handlers[id] = nil
            self.releaseHandlers[id] = nil
            self.carbonSpecs[id] = nil
        }
    }

    /// Temporarily unregister every Carbon hotkey -- used while a shortcut
    /// recorder captures a keystroke, so an already-bound combo falls through to
    /// normal key dispatch (the recorder) instead of firing its action. Chords
    /// ride HotkeyCenter too, so this covers them. Balanced and re-entrant: pair
    /// each `suspend()` with a `resume()`.
    func suspend() {
        suspendDepth += 1
        guard suspendDepth == 1 else { return }
        for (id, ref) in refs {
            UnregisterEventHotKey(ref)
            suspendedIds.insert(id)
        }
        refs.removeAll()
    }

    func resume() {
        guard suspendDepth > 0 else { return }
        suspendDepth -= 1
        guard suspendDepth == 0 else { return }
        for id in suspendedIds {
            guard let spec = carbonSpecs[id] else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x48_44_4B_59), id: id)
            if RegisterEventHotKey(spec.keyCode, spec.mods, hkID,
                                   GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                refs[id] = ref
            }
        }
        suspendedIds.removeAll()
    }

    /// Carbon virtual key codes, keyed by the lowercase names features use.
    /// Built from the named `kVK_*` constants (not raw integers) so every entry
    /// is compiler-verified -- a mistyped name fails the build rather than
    /// silently binding the wrong key.
    ///
    /// CAVEAT -- these codes are *positional* (US/ANSI layout): a code maps to a
    /// physical key location, not the character it produces. On a non-US layout
    /// the same code fires the key in the US-qwerty position, which may print a
    /// different character. Fine for the single-author owner; a future
    /// layout-aware pass (UCKeyTranslate against the active layout) would map
    /// characters -> codes properly.
    static let keyCodes: [String: Int] = [
        // letters
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        // digits
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        // punctuation
        "=": kVK_ANSI_Equal, "-": kVK_ANSI_Minus, "]": kVK_ANSI_RightBracket,
        "[": kVK_ANSI_LeftBracket, "'": kVK_ANSI_Quote, ";": kVK_ANSI_Semicolon,
        "\\": kVK_ANSI_Backslash, ",": kVK_ANSI_Comma, "/": kVK_ANSI_Slash,
        ".": kVK_ANSI_Period, "`": kVK_ANSI_Grave,
        // editing / whitespace
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
        "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete,
        "escape": kVK_Escape, "esc": kVK_Escape,
        // navigation
        "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "down": kVK_DownArrow, "up": kVK_UpArrow,
        "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "help": kVK_Help,
        // function keys
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
        "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
        "f19": kVK_F19, "f20": kVK_F20,
        // keypad
        "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1,
        "keypad2": kVK_ANSI_Keypad2, "keypad3": kVK_ANSI_Keypad3,
        "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
        "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7,
        "keypad8": kVK_ANSI_Keypad8, "keypad9": kVK_ANSI_Keypad9,
        "keypaddecimal": kVK_ANSI_KeypadDecimal, "keypadplus": kVK_ANSI_KeypadPlus,
        "keypadminus": kVK_ANSI_KeypadMinus, "keypadmultiply": kVK_ANSI_KeypadMultiply,
        "keypaddivide": kVK_ANSI_KeypadDivide, "keypadequals": kVK_ANSI_KeypadEquals,
        "keypadenter": kVK_ANSI_KeypadEnter, "keypadclear": kVK_ANSI_KeypadClear,
    ]
}
