// Native.swift split: this file is one domain slice of the `Native` seam (see
// Native.swift for the class, shared state, and installBindings). Synchronous
// AppleScript: the ONE chokepoint every in-process osascript-shaped call in the
// seam goes through.
//
// WHY THIS FILE EXISTS -- the 2026-07-23 freeze. NSAppleScript.executeAndReturnError
// blocks the MAIN THREAD, and while it waits it spins a NESTED event loop, so
// main-loop timers keep firing INSIDE the wait and re-enter Lua mid-call. That
// evening usage_stats read the active browser URL just as Chrome went away; the
// Apple Event to the absent app never came back, window_fan's 2s poll fired
// inside that nested loop and hit an equally unbounded AX read, and the app
// played dead for 25+ seconds. It read as a dead loop but burned ~0% CPU -- it
// was a hang report, not a crash.
//
// Two rules close that whole class, and they live HERE so no future caller can
// forget them:
//
//   1. NEVER send an Apple Event to an app that is not running, unless the
//      caller genuinely wants the launch. `tell application "X"` LAUNCHES a cold
//      X and blocks until it is scriptable -- unbounded, and pointless for a
//      read ("what is the browser looking at" has no answer if it is not open).
//      Pass `requiring:` to gate on liveness.
//
//   2. ALWAYS bound the wait. `with timeout of N seconds` is the only mechanism
//      that bounds an Apple Event send -- NSAppleScript exposes no timeout of its
//      own. Expiry arrives as an ordinary script error (-1712), so every caller's
//      existing degrade-on-nil path already handles it.
//
// Note what these rules do NOT do: timers still fire inside the nested loop and
// still re-enter Lua. Suppressing those ticks was tried and reverted -- it
// silently loses work (see the note above timerEvery in Native+Triggers). The
// nesting is made SURVIVABLE by bounding both waits, not prevented.
//
// For anything bigger than a single property read, the ASYNC OUT-OF-PROCESS path
// (runJXA in Native+Browser) remains the preferred shape: a subprocess cannot
// hang the host at all. This file is for the calls that must return a value
// synchronously to Lua.

import AppKit

extension Native {
    /// Is an app with this localized name running RIGHT NOW? The liveness gate in
    /// front of every `tell application "<name>"`.
    ///
    /// Matched on `localizedName` because that is what the seam's callers already
    /// use (`app_running`, the curated browser names). It is NOT identical to the
    /// name AppleScript resolves through LaunchServices, so the two could in
    /// principle disagree for an app whose display name is localized -- harmless
    /// for the curated Chrome/Safari set, but do not treat this as an exact
    /// identity check when adding a target.
    ///
    /// The gate is necessary, not sufficient: an app that is MID-QUIT still
    /// appears here, and it can exit between this check and the send. Those are
    /// exactly the cases `with timeout` covers -- both halves are load-bearing.
    static func appIsRunning(named name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }

    /// Run a CURATED AppleScript synchronously, bounded and optionally gated on the
    /// target app being alive. Returns the result descriptor, or nil when the
    /// target is absent, the script errored, or the wait timed out -- callers
    /// degrade on nil, which they already had to do for the error case.
    ///
    /// - Parameters:
    ///   - source: the script body. Never caller-supplied text; these are fixed
    ///     templates in the seam.
    ///   - target: app name to require alive before sending anything. nil means
    ///     "send regardless" -- correct ONLY when launching the target is the
    ///     point (a focus-or-open action) or the target is an always-available
    ///     system agent.
    ///   - timeout: hard ceiling on the Apple Event wait, in seconds.
    ///   - label: short tag for the failure log line.
    func runAppleScript(_ source: String,
                        requiring target: String? = nil,
                        timeout: TimeInterval,
                        label: String) -> NSAppleEventDescriptor? {
        if let target, !Native.appIsRunning(named: target) {
            // Not an error: "not running" is a legitimate, common answer. Silent
            // by design -- this is the fast path on every poll tick while no
            // browser is open, and logging it would drown the daily log.
            return nil
        }
        // `with timeout` wraps the whole body; `return` inside it still returns
        // from the script's run handler (verified against osascript, and the -1712
        // expiry reproduced against a deliberately slow target, before this was
        // relied on). Seconds must be a whole number for the AppleScript literal;
        // clamped because this is a chokepoint and `Int(_:)` traps on a
        // non-finite Double.
        let seconds = timeout.isFinite ? min(max(1, Int(timeout.rounded())), 600) : 5
        let bounded = """
            with timeout of \(seconds) seconds
            \(source)
            end timeout
            """
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: bounded)?.executeAndReturnError(&errInfo)
        if let errInfo {
            // seamLog, not print: a seam failure that reaches only stdout is
            // invisible in a post-mortem. The 2026-07-23 hang left NO trace in the
            // daily log, which is exactly what made it expensive to diagnose.
            //
            // THROTTLED by label: these sit on poll paths (a browser URL read runs
            // every few seconds while browsing), so a persistent failure -- denied
            // Automation, a wedged app -- would write a line per tick and bury the
            // log. The old code was silent here, so un-throttled logging would be a
            // regression dressed as an improvement.
            seamLogThrottled(label, "\(label) AppleScript failed: "
                + ((errInfo[NSAppleScript.errorMessage] as? String) ?? "\(errInfo)"))
            return nil
        }
        return result
    }
}
