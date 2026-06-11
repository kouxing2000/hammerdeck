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
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextId: UInt32 = 1
    private var installed = false

    private init() {}

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            // Carbon dispatches on the main thread.
            MainActor.assumeIsolated {
                HotkeyCenter.shared.handlers[hkID.id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns an unregister closure, or nil if the key is unknown.
    func bind(mods: [String], key: String, handler: @escaping () -> Void) -> (() -> Void)? {
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
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x48_44_4B_59) /* 'HDKY' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), carbonMods, hkID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let hotkeyRef = ref else { return nil }

        handlers[id] = handler
        refs[id] = hotkeyRef
        return { [weak self] in
            guard let self, let r = self.refs[id] else { return }
            UnregisterEventHotKey(r)
            self.refs[id] = nil
            self.handlers[id] = nil
        }
    }

    /// US-layout virtual key codes (kVK_*). Grows as features need keys.
    static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
