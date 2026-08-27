import AppKit

// Relaunch the app -- used after the user confirms a language change. A fresh
// boot re-resolves the locale and rebuilds all UI from scratch, so no live
// re-render plumbing is needed (and nothing can silently go stale).
//
// Mechanism: spawn a detached /bin/sh that waits for THIS process to exit, then
// reopens the bundle -- so `open` doesn't just refocus the dying instance.
// Best-effort: in a dev `swift run` (no .app bundle) the reopen may not apply,
// but the preference is already saved, so the next manual start picks it up.
@MainActor
enum AppRelaunch {
    /// `at` names the bundle to reopen, which is NOT always our own: the
    /// install-location guard has just MOVED us, so the copy worth starting is the
    /// one at the new path and the one running is about to stop existing.
    ///
    /// `thenExit` picks how this process dies. `NSApp.terminate` is right once the
    /// run loop is up; the install guard runs BEFORE it starts, where terminate has
    /// nothing to service it and the process would sit there with no UI.
    static func restart(at bundlePath: String = Bundle.main.bundlePath,
                        thenExit: Bool = false) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Pass pid/path as positional args ($0/$1), NOT interpolated into the
        // script body -- so a bundle path containing quotes/spaces can't break it.
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$1\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, String(pid), bundlePath]
        try? task.run()
        if thenExit { exit(0) }
        NSApp.terminate(nil)
    }
}
