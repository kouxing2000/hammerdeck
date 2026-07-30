import AppKit
import Carbon.HIToolbox   // kVK_F18
import CoreGraphics
import IOKit
import IOKit.hidsystem    // IOHID{Get,Set}ModifierLockState, kIOHIDCapsLockState

/// "Caps Lock acts as Hyper (⌘⌥⌃)" -- turns the left-pinky Caps key into a
/// momentary Hyper modifier so the global Hyper hotkeys become a one-key press
/// (the ergonomic fix for "Hyper + a left-hand letter is a one-hand cramp").
///
/// WHY TWO STEPS. macOS hands a CGEventTap only the LOCK *toggle* of Caps (one
/// flagsChanged on, one off) -- never a press-and-hold edge -- so a tap alone
/// cannot do momentary Caps. The standard recipe (what Karabiner does) fixes it:
///   1. `hidutil` remaps the physical Caps key to F18, a plain non-locking key,
///      so it now emits clean key-down / key-up.
///   2. this CGEventTap watches F18: while it is held it OR's ⌘⌥⌃ onto every
///      OTHER key event (so the existing Carbon hotkeys fire) and swallows F18
///      itself so it types nothing. A DOUBLE-TAP of Caps (two clean taps with no
///      other key between, within ~300ms) toggles the real Caps Lock via IOKit,
///      so the lock isn't lost -- it just moves to a double-tap. A single tap is
///      inert.
/// `disable()` reverses both -- a toggle-off or clean quit restores plain Caps
/// (the willTerminate hook calls disable()). The hidutil remap is session-only
/// (gone after a reboot) but DOES outlive a crash/force-kill: Caps stays a dead
/// key until the next launch, where apply() reconciles it (re-enables the tap,
/// or clears the remap when the pref is now off).
///
/// Needs the Accessibility grant (a tap that REWRITES events). The host owns the
/// AX onboarding already (Native+Windows axTrusted/axPrompt); the caller
/// (CapsHyperPreference) prompts when `enable()` reports no grant.
///
/// CAVEAT (verify on-device): whether Carbon `RegisterEventHotKey` observes the
/// flags we inject at the session tap is the load-bearing assumption -- it holds
/// for a head-inserted .cgSessionEventTap, but it is empirical. Bind Hyper+Space
/// (command_palette) and confirm Caps+Space opens the palette.
@MainActor
final class CapsHyperTap {
    static let shared = CapsHyperTap()
    private init() {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var f18Held = false
    // Double-tap detection (timestamps are CGEvent nanoseconds since boot).
    fileprivate var f18DownTimestamp: UInt64 = 0
    fileprivate var usedAsModifier = false      // a key fired while Caps was held
    fileprivate var lastTapTimestamp: UInt64 = 0
    private static let tapMaxNs: UInt64 = 250_000_000     // press < 250ms = a tap
    private static let doubleWindowNs: UInt64 = 300_000_000 // <300ms apart = double

    /// Supplies the which-key legend rows (the host wires this to read the live
    /// catalog). Shown in a HUD card when Caps is HELD past a short delay.
    var legendProvider: (() -> [HyperHintPanel.Row])?
    /// Runs one feature action by (featureId, actionId) -- the host wires it to
    /// registry.runAction, the same entry the menubar's quick triggers use. Kept
    /// as a closure (like legendProvider) so this file knows nothing about Lua.
    /// Returns nil on success, or WHY it did not run, which the caller logs.
    var actionRunner: ((String, String) -> String?)?
    private var legendPanel: HyperHintPanel?
    private var legendTask: Task<Void, Never>?
    private static let legendDelayNs: UInt64 = 300_000_000  // hold this long -> show
    /// The prefix a legend row's key sits on, by construction of hyperLegend.
    private static let hyperModNames = ["cmd", "alt", "ctrl"]

    // nonisolated: read from the C tap callback, which runs outside the actor.
    fileprivate nonisolated static let hyperFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
    fileprivate nonisolated static let f18KeyCode = CGKeyCode(kVK_F18)   // 79

    var isEnabled: Bool { tap != nil }

    /// Remap Caps→F18 and start the tap. Returns false when the tap cannot be
    /// created (no Accessibility grant) -- the caller then prompts and re-applies.
    @discardableResult
    func enable() -> Bool {
        guard tap == nil else { return true }
        Self.remapCapsToF18(true)

        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: capsHyperCallback, userInfo: refcon)
        else {
            // Denied (no grant): undo the remap so Caps isn't stranded as F18.
            Self.remapCapsToF18(false)
            return false
        }
        tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func disable() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
            CFMachPortInvalidate(port)
        }
        tap = nil
        source = nil
        f18Held = false
        usedAsModifier = false
        lastTapTimestamp = 0
        cancelAndHideLegend()
        Self.remapCapsToF18(false)
    }

    /// Re-arm after the system parks the tap (timeout / heavy input burst).
    fileprivate func rearm() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// A Caps(F18) key edge. Down: start tracking a possible tap. Up: if it was a
    /// clean tap (short, no key used while held), pair it with a recent one to
    /// toggle the real Caps Lock; a lone tap is inert.
    fileprivate func handleCapsEdge(down: Bool, timestamp: UInt64) {
        if down {
            f18Held = true
            f18DownTimestamp = timestamp
            usedAsModifier = false
            scheduleLegend()   // appears only if the hold outlasts the delay
            return
        }
        f18Held = false
        cancelAndHideLegend()   // release -> drop the hint (and any pending show)
        let wasTap = !usedAsModifier
            && timestamp >= f18DownTimestamp
            && (timestamp - f18DownTimestamp) < Self.tapMaxNs
        if wasTap {
            if lastTapTimestamp != 0 && timestamp >= lastTapTimestamp
                && (timestamp - lastTapTimestamp) < Self.doubleWindowNs {
                Self.toggleSystemCapsLock()   // double-tap -> real Caps Lock
                lastTapTimestamp = 0
            } else {
                lastTapTimestamp = timestamp   // first tap; a single tap does nothing
            }
        } else {
            lastTapTimestamp = 0   // a held/used Caps breaks any pending double-tap
        }
    }

    /// Whether Caps(F18) is held; if so, mark the hold as a real modifier use so
    /// its eventual release isn't mistaken for a clean tap.
    fileprivate func noteHyperUseIfHeld() -> Bool {
        if f18Held {
            usedAsModifier = true
            cancelAndHideLegend()   // a key was chosen -> the hint's job is done
        }
        return f18Held
    }

    // MARK: which-key legend (shown while Caps is held and you pause)

    fileprivate func scheduleLegend() {
        legendTask?.cancel()
        legendTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.legendDelayNs)
            guard !Task.isCancelled, self.f18Held, self.legendPanel == nil else { return }
            self.legendPanel = self.makeLegendPanel()
        }
    }

    /// The legend card, wired so CLICKING a lit key does what pressing it would.
    private func makeLegendPanel() -> HyperHintPanel {
        HyperHintPanel(rows: legendProvider?() ?? [],
                       onActivate: { [weak self] row in self?.activateLegendRow(row) },
                       // Same teardown a key press takes: the card is done for
                       // this hold and does not come back until Caps is re-held.
                       onDismiss: { [weak self] in self?.cancelAndHideLegend() })
    }

    /// A key cap on the legend was clicked -- the pointer twin of pressing it.
    private func activateLegendRow(_ row: HyperHintPanel.Row) {
        // A click IS a use of this hold: without marking it, releasing Caps
        // could still read as a clean tap and arm the double-tap Caps Lock.
        usedAsModifier = true
        cancelAndHideLegend()

        // Capture as plain values, then run on the NEXT main-loop pass: the HUD
        // is already gone when the action starts, so an action that opens its
        // own panel isn't building one while this click is still unwinding.
        let chord = row.chord, key = row.key
        let featureId = row.featureId, actionId = row.actionId
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // A click that does NOTHING is this HUD's worst failure -- the
                // card is already gone, so the only evidence left is what we
                // log. It is reachable: a feature whose bind threw keeps its
                // enabled flag (registry.lua "enabled but failed"), so its cap
                // still lights up while neither path below can act on it.
                if chord {
                    // A chord key is only a PREFIX -- several actions can share
                    // it, and the board shows just one of them -- so a click
                    // ARMS the chord (which pops its own follow-key hint)
                    // instead of picking one arbitrarily.
                    if !ChordCenter.shared.pressPrefix(mods: Self.hyperModNames, key: key) {
                        Native.shared.seamLog(
                            "hyper legend: clicked chord key '\(key)' but no chord is bound on it")
                    }
                } else if let why = CapsHyperTap.shared.actionRunner?(featureId, actionId) {
                    Native.shared.seamLog(
                        "hyper legend: clicked \(featureId).\(actionId) but it did not run -- \(why)")
                }
            }
        }
    }

    fileprivate func cancelAndHideLegend() {
        legendTask?.cancel()
        legendTask = nil
        legendPanel?.close()
        legendPanel = nil
    }

#if DEBUG
    /// Show the which-key legend on demand for a visual check (DebugControl
    /// `@hyperhint`), reading the live catalog -- bypasses the Caps-hold path.
    /// TOGGLES: shown this way the card has no Caps release to tear it down, so
    /// without a second call it sits on the screen (mouse-opaque) until the app
    /// restarts. Returns true when it just showed the card.
    @discardableResult
    func debugPreviewLegend() -> Bool {
        guard legendPanel == nil else { cancelAndHideLegend(); return false }
        legendPanel = makeLegendPanel()
        return true
    }
#endif

    /// Toggle the system Caps Lock state + LED via IOKit (the remap means the key
    /// itself no longer locks, so a double-tap drives the lock programmatically).
    private static func toggleSystemCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_,
                            UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS else { return }
        defer { IOServiceClose(conn) }
        var state = false
        IOHIDGetModifierLockState(conn, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), !state)
    }

    // MARK: hidutil Caps <-> F18 remap (per-session, reversible)

    /// Caps Lock HID usage 0x700000039 -> F18 usage 0x70000006D (on), or clear
    /// the whole UserKeyMapping (off). NOTE: hidutil --set replaces the entire
    /// mapping list, so toggling this off also clears any other hidutil key
    /// remaps -- acceptable for this single-author app, which owns the Caps remap.
    private static func remapCapsToF18(_ on: Bool) {
        let mapping = on
            ? #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
            : #"{"UserKeyMapping":[]}"#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", mapping]
        try? p.run()
        p.waitUntilExit()
    }
}

/// The C tap callback: runs on the main run loop (we add the source there), so
/// the @MainActor hops are real-thread-correct.
private func capsHyperCallback(proxy: CGEventTapProxy, type: CGEventType,
                               event: CGEvent, refcon: UnsafeMutableRawPointer?)
    -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<CapsHyperTap>.fromOpaque(refcon).takeUnretainedValue()

    // The system disables the tap on timeout / overload; re-enable, pass through.
    // Re-arming means we may have missed the Caps(F18) key-up while parked, so
    // CLEAR the hold -- otherwise a dropped key-up wedges every later keystroke
    // as Hyper+key with no obvious cause. Worst case is one missed hold the user
    // simply re-presses, vs. a stuck keyboard.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { me.f18Held = false; me.cancelAndHideLegend(); me.rearm() }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

    // F18 (the remapped Caps) is our modifier: track the hold / double-tap edge
    // and SWALLOW the key so it never types or fires anything on its own.
    if keyCode == CapsHyperTap.f18KeyCode && (type == .keyDown || type == .keyUp) {
        let ts = event.timestamp
        MainActor.assumeIsolated { me.handleCapsEdge(down: type == .keyDown, timestamp: ts) }
        return nil
    }

    // While Caps(F18) is held, every other key reads as Hyper+key (and marks the
    // hold as "used", so its release is not a clean tap).
    if MainActor.assumeIsolated({ me.noteHyperUseIfHeld() }) {
        event.flags.insert(CapsHyperTap.hyperFlags)
    }
    return Unmanaged.passUnretained(event)
}
