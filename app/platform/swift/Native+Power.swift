// Native.swift split: this file is one domain slice of the `Native` seam (see
// Native.swift for the class, shared state, and installBindings).
// Power: the AC-vs-battery read behind the `powerSource` state signal. The
// matching powerChanged observer lives in Native+Triggers.swift (it shares the
// onSystemEvent plumbing with the other system events).

import AppKit
import CLua
import IOKit.ps

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
}
