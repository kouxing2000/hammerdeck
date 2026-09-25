// Native.swift split: this file is one domain slice of the `Native` seam (see
// Native.swift for the class, shared state, and installBindings).
// Power: the AC-vs-battery read behind the `powerSource` state signal, and the
// display-sleep power-assertion read. The matching powerChanged observer lives
// in Native+Triggers.swift (it shares the onSystemEvent plumbing with the other
// system events).

import AppKit
import CLua
import IOKit.ps
import IOKit.pwr_mgt

extension Native {
    // power_source() -> "ac" (plugged in) | "battery". The system's *providing*
    // power source via IOKit; the powerChanged event re-reads this on change.
    func powerSource(_ L: OpaquePointer?) -> Int32 {
        // IOPSCopyPowerSourcesInfo is a "Copy" (we own it -> takeRetained);
        // IOPSGetProvidingPowerSourceType is a "Get" (we do NOT own it ->
        // takeUnretained, or we'd over-release a reference we were never granted).
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        lua_pushstring(L, type == kIOPSACPowerValue ? "ac" : "battery")
        return 1
    }

    // The two assertion types that mean "keep the panel lit". `NoDisplaySleep`
    // is the legacy one; `PreventUserIdleDisplaySleep` is what current AVFoundation
    // playback, Chrome/Safari video, screen sharing and presentation modes take.
    private static let displayWakeAssertions: Set<String> = [
        kIOPMAssertionTypeNoDisplaySleep as String,
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
    ]

    // display_sleep_prevented() -> holderName|nil.
    //
    // Non-nil while SOME process holds a power assertion that keeps the display
    // awake -- the exact signal macOS's own idle-display-sleep obeys. This is the
    // missing half of any idle-timer feature: HID idle time only says "nobody
    // touched a key", which is ALSO what watching a two-hour film looks like.
    // Reading the assertion is what tells the two apart, and it does so without an
    // app whitelist -- every video player, video call and presentation app takes
    // one, so they all work for free.
    //
    // Returns the holding process's name (for the log/banner) or nil when nothing
    // holds one. Cheap and safe on the main thread: IOPMCopyAssertions* are IOKit
    // registry reads, NOT Apple Events -- no nested event loop, nothing to
    // time-box (cf. the runAppleScript rule in Native+AppleScript.swift).
    func displaySleepPrevented(_ L: OpaquePointer?) -> Int32 {
        var statusRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&statusRef) == kIOReturnSuccess,
              let aggregate = statusRef?.takeRetainedValue() as? [String: Int],
              Native.displayWakeAssertions.contains(where: { (aggregate[$0] ?? 0) > 0 })
        else {
            lua_pushnil(L)
            return 1
        }
        lua_pushstring(L, displayAssertionHolder() ?? "another app")
        return 1
    }

    // Best-effort name of a process holding a display-wake assertion. Only called
    // once the cheap aggregate read above says one IS held, so the per-process
    // walk stays off the common path. The assertion dictionaries carry a process
    // name on current macOS, but it is not a public constant -- fall back to
    // resolving the pid key through NSRunningApplication, then to the raw pid.
    private func displayAssertionHolder() -> String? {
        var byProcessRef: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcessRef) == kIOReturnSuccess,
              let byProcess = byProcessRef?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        for (pidKey, assertions) in byProcess {
            let holds = assertions.contains { entry in
                guard let type = entry[kIOPMAssertionTypeKey] as? String else { return false }
                return Native.displayWakeAssertions.contains(type)
            }
            guard holds else { continue }
            if let named = assertions.compactMap({ $0["Process Name"] as? String }).first,
               !named.isEmpty {
                return named
            }
            let pid = pid_t(truncatingIfNeeded: pidKey.intValue)
            if let app = runningApplication(pid: pid),
               let name = app.localizedName {
                return name
            }
            return "pid \(pid)"
        }
        return nil
    }
}
