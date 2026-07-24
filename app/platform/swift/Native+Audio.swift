// Native.swift split: this file is one domain slice of the `Native` seam (see
// Native.swift for the class, shared state, and installBindings). Audio: nudge
// the system output volume and toggle mute, via AppleScript -- the public,
// entitlement-free path, the same idiom as set_appearance. The relative step is
// the caller's; the seam clamps the result to the 0-100 hardware range and does
// the read-modify-write in ONE NSAppleScript (no second adapter round-trip). It's
// serialized against other Lua callers, though a concurrent hardware media-key
// change landing between the read and the write could clobber it -- negligible
// at human pace.

import AppKit
import CLua

extension Native {
    // adjust_volume(delta) -> Int  -- add `delta` (may be negative) to the current
    // system output volume, clamp to 0...100, apply, and return the new level
    // (-1 on an AppleScript error, so the feature can tell a no-op from a change).
    func adjustVolume(_ L: OpaquePointer?) -> Int32 {
        let delta = LuaState.int(L, 1) ?? 0
        let script = """
        set cur to output volume of (get volume settings)
        set newVol to cur + (\(delta))
        if newVol > 100 then set newVol to 100
        if newVol < 0 then set newVol to 0
        set volume output volume newVol
        return newVol
        """
        let level = runAudioScript(script)?.int32Value ?? -1
        lua_pushinteger(L, lua_Integer(level))
        return 1
    }

    // toggle_mute() -> bool  -- flip the system output mute and return the NEW
    // muted state (false on error -- the safe "audible" default).
    func toggleMute(_ L: OpaquePointer?) -> Int32 {
        let script = """
        set m to output muted of (get volume settings)
        set volume output muted (not m)
        return (not m)
        """
        let muted = runAudioScript(script)?.booleanValue ?? false
        lua_pushboolean(L, muted ? 1 : 0)
        return 1
    }

    /// Run an AppleScript source and return its result descriptor, or nil (logged)
    /// on a compile/run error. AppleScript output-volume control needs no entitlement.
    ///
    /// The lowest-risk of the seam's AppleScript calls: `get volume settings` is a
    /// StandardAdditions command with no `tell application` target, so there is no
    /// other app to be absent or wedged, and nothing to liveness-gate. It still
    /// goes through the bounded chokepoint -- these actions are automatable, and a
    /// uniform ceiling is cheaper than reasoning about which call is "safe enough".
    private func runAudioScript(_ source: String) -> NSAppleEventDescriptor? {
        runAppleScript(source, timeout: 5, label: "audio")
    }
}
